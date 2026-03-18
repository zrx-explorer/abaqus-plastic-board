#!/bin/bash
#SBATCH -J plastic-board-batch
#SBATCH -p operation
#SBATCH -t 60:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --mem=100GB
#SBATCH --array=0-999
#SBATCH -o log/log_%A_%a.txt

curdir=$PWD

module purge
module add abaqus/2022
export I_MPI_PMI_LIBRARY=/opt/gridview/slurm/lib/libpmi2.so
module load compiler/intel/2021.3.0 mpi/intelmpi/2021.3.0
ulimit -s unlimited

infile='tasks.txt'
materialsfile='materials.txt'
outdir='/public/home/nieqi01/zrx/20260310abq-pla/res/'
roscript='./run-plastic-board.sh'
loadBalance=''
srcdir='.'
timelimit='1h'
poisson_ration=0.3
density=2.7e-09

scriptG=${srcdir}/get-standard-pid.sh


mkdir -p $outdir
mkdir -p log

if [[ ! -e "$infile" ]]; then
    echo "Error: Input file '$infile' not found"
    exit 1
fi

if [[ ! -e "$materialsfile" ]]; then
    echo "Error: Materials file '$materialsfile' not found"
    exit 1
fi

if [[ ! -e "$roscript" ]]; then
    echo "Error: Run script '$roscript' not found"
    exit 1
fi

if [[ ! -e "$scriptG" ]]; then
    echo "Error: Helper script '$scriptG' not found"
    exit 1
fi

readarray -t material_lines < "$materialsfile"
num_materials=${#material_lines[@]}
echo ">>> Loaded $num_materials material sets from $materialsfile"

result_csv="${outdir}/result.csv"
failure_csv="${outdir}/result_failure.csv"
time_csv="${outdir}/result_time.csv"

# 初始化 result.csv（每个 STP 文件一行，x/y/z 三列）
if [[ ! -e "$result_csv" ]]; then
    echo "stp_file,young_module,yield_stress,result_x_force,result_x_strength,result_y_force,result_y_strength,result_z_force,result_z_strength" > "$result_csv"
fi

# 初始化 result_failure.csv
if [[ ! -e "$failure_csv" ]]; then
    echo "stp_file,young_module,yield_stress,direction,error_type,error_message" > "$failure_csv"
fi

# 初始化 result_time.csv（计算时间记录）
if [[ ! -e "$time_csv" ]]; then
    echo "stp_file,young_module,yield_stress,direction,start_time,end_time,duration_seconds,status" > "$time_csv"
fi



function cal_job(){
    path=$1
    direction=$2

    bname=$(basename $path)
    pbname=${bname%.*}

    stp_filename=$(basename $path)
    stp_filename=${stp_filename%.*}

    model_dir="${outdir}/${pbname}.${direction}"
    work_dir="${model_dir}/${stp_filename}_E${young_module}_Y${yield_stress}_${direction}"
    csv_file="${stp_filename}_E${young_module}_Y${yield_stress}_${direction}.csv"
    failed_csv_file="${stp_filename}_E${young_module}_Y${yield_stress}_${direction}_failed.csv"

    if [[ -e $work_dir/$csv_file ]]; then
        echo "sbatch.sh: result csv already exists in $work_dir, skip it"
        return
    fi
    
    if [[ -e $work_dir/$failed_csv_file ]]; then
        echo "sbatch.sh: failed csv exists in $work_dir, skip it"
        return
    fi

    if [[ "$direction" == "x" ]]; then
        outdirC2=${outdir}/${pbname}.y
        outdirC3=${outdir}/${pbname}.z
    elif [[ "$direction" == "y" ]]; then
        outdirC2=${outdir}/${pbname}.x
        outdirC3=${outdir}/${pbname}.z
    else
        outdirC2=${outdir}/${pbname}.x
        outdirC3=${outdir}/${pbname}.y
    fi

    mkdir -p $model_dir

    if [[ -e ${outdirC2}/abaqusError || -e ${outdirC3}/abaqusError ]]; then
        echo "sbatch.sh: abaqusError exists in ${outdirC2} or ${outdirC3}, skip $path $direction"
        touch $model_dir/abaqusError
        return
    fi

    if [[ -e ${outdirC2}/timeoutNote || -e ${outdirC3}/timeoutNote ]]; then
        echo "sbatch.sh: timeoutNote exists in ${outdirC2} or ${outdirC3}, skip $path $direction"
        touch $model_dir/timeoutNote
        return
    fi

    if [[ -e ${outdirC2}/skipNote || -e ${outdirC3}/skipNote ]]; then
        echo "sbatch.sh: skipNote exists in ${outdirC2} or ${outdirC3}, skip $path $direction"
        touch $model_dir/skipNote
        return
    fi

    # Record start time
    start_time=$(date +%s)
    start_datetime=$(date '+%Y-%m-%d %H:%M:%S')
    
    timeout $timelimit $roscript -i $path -o $model_dir -${direction} -c 120 -n 1 -e \
        -E $young_module -P $poisson_ration -Y $yield_stress -R $density >& $model_dir/during.log
    exit_code=$?
    
    # Record end time and calculate duration
    end_time=$(date +%s)
    end_datetime=$(date '+%Y-%m-%d %H:%M:%S')
    duration=$((end_time - start_time))
    
    error_type=""
    error_msg=""
    status="success"
    
    # Check timeout
    if [[ $exit_code -eq 124 ]]; then
        echo "Warning! timeout for $path $direction, killing all related processed ..."
        touch $model_dir/timeoutNote
        timeout_csv="${stp_filename}_E${young_module}_Y${yield_stress}_timeout.csv"
        echo "Error: Simulation timeout" > $model_dir/$timeout_csv
        psline=$($scriptG $model_dir)
        if [[ -n "$psline" ]]; then
            pid=$(echo $psline | awk '{print $1}')
            echo "   - Simulation timeout, killing process $pid"
            kill -9 $pid
        fi
        sleep 5
        cd $model_dir
        rm -rf *.odb *.stt *.mdl *.prt *.simdir
        rm -rf Job-Compression-Run.* *.sat *.py *.rec abaqusis.env abaqus_acis.log abaqus1.rec
        cd $curdir
        error_type="timeout"
        error_msg="Simulation timeout after $timelimit"
        status="timeout"
    fi
    
    # Check abaqusError marker file (created by run-plastic-board.sh)
    if [[ -e $model_dir/abaqusError ]]; then
        error_type="abaqus_error"
        # Extract detailed error from during.log
        error_msg=$(grep -i "error\|failed\|exception" $model_dir/during.log 2>/dev/null | head -3 | tr '\n' ' ' | tr ',' ';')
        if [[ -z "$error_msg" ]]; then
            error_msg="Abaqus error detected (see during.log for details)"
        fi
        status="error"
    fi
    
    # Check if run-plastic-board.sh created a failed CSV
    if [[ -e $work_dir/$failed_csv_file ]]; then
        error_type="simulation_failed"
        # Read error from failed CSV
        error_msg=$(cat $work_dir/$failed_csv_file 2>/dev/null | head -2 | tr '\n' ' ' | tr ',' ';')
        if [[ -z "$error_msg" ]]; then
            error_msg="Simulation failed (see failed CSV)"
        fi
        status="failed"
    fi
    
    # Check skipNote marker
    if [[ -e $model_dir/skipNote ]]; then
        error_type="skipped"
        error_msg="Task skipped (too many elements or warning elements)"
        status="skipped"
    fi
    
    # Check for other errors in during.log even if no marker file exists
    if [[ -z "$error_type" && $exit_code -ne 0 ]]; then
        error_type="execution_error"
        error_msg=$(grep -i "error\|failed\|exception" $model_dir/during.log 2>/dev/null | head -3 | tr '\n' ' ' | tr ',' ';')
        if [[ -z "$error_msg" ]]; then
            error_msg="Exit code: $exit_code"
        fi
        status="error"
    fi
    
    # Record failure to result_failure.csv
    if [[ -n "$error_type" ]]; then
        echo "$stp_filename,$young_module,$yield_stress,$direction,$error_type,$error_msg" >> "$failure_csv"
        echo "  -> Recorded failure: $error_type"
    fi
    
    # Record timing to result_time.csv
    echo "$stp_filename,$young_module,$yield_stress,$direction,$start_datetime,$end_datetime,$duration,$status" >> "$time_csv"

}

function collect_results(){
    path=$1
    young_module=$2
    yield_stress=$3
    
    bname=$(basename $path)
    pbname=${bname%.*}
    stp_filename=$(basename $path)
    stp_filename=${stp_filename%.*}
    
    result_x_force="" result_x_strength=""
    result_y_force="" result_y_strength=""
    result_z_force="" result_z_strength=""
    
    for dir in x y z; do
        model_dir="${outdir}/${pbname}.${dir}"
        work_dir="${model_dir}/${stp_filename}_E${young_module}_Y${yield_stress}_${dir}"
        csv_file="${stp_filename}_E${young_module}_Y${yield_stress}_${dir}.csv"
        result_csv_path="$work_dir/$csv_file"
        
        if [[ -e "$result_csv_path" ]]; then
            yield_line=$(grep "^#.*YIELD_FORCE_N=" "$result_csv_path" | head -1)
            if [[ -n "$yield_line" ]]; then
                force=$(echo "$yield_line" | sed 's/.*YIELD_FORCE_N=\([^,]*\).*/\1/' | tr -d ' ')
                strength=""
                if [[ "$force" != "Not_Reached" && -n "$force" ]]; then
                    area_a0=$(echo "$yield_line" | sed 's/.*AREA_A0=\([0-9.]*\).*/\1/' | tr -d ' ')
                    if [[ -n "$area_a0" && "$area_a0" != "0" ]]; then
                        strength=$(awk "BEGIN {printf \"%.4f\", $force / $area_a0}")
                    fi
                fi
                
                if [[ "$dir" == "x" ]]; then
                    result_x_force="$force"
                    result_x_strength="$strength"
                elif [[ "$dir" == "y" ]]; then
                    result_y_force="$force"
                    result_y_strength="$strength"
                else
                    result_z_force="$force"
                    result_z_strength="$strength"
                fi
            fi
        fi
    done
    
    echo "$stp_filename,$young_module,$yield_stress,$result_x_force,$result_x_strength,$result_y_force,$result_y_strength,$result_z_force,$result_z_strength" >> "$result_csv"
}


if [[ -z "$loadBalance" ]]; then
    echo ">>> Load balancing mode unenabled."

    nlines=$(wc -l < $infile)

    (( njobs = nlines / SLURM_ARRAY_TASK_COUNT ))
    (( nleft = nlines % SLURM_ARRAY_TASK_COUNT ))
    if (( SLURM_ARRAY_TASK_ID < nlines % SLURM_ARRAY_TASK_COUNT )); then
        (( njobs++ ))
        (( line_start = SLURM_ARRAY_TASK_ID * njobs + 1 ))
    else
        (( line_start = nleft * (njobs + 1) + (SLURM_ARRAY_TASK_ID-nleft) * njobs + 1 ))
    fi

    if (( njobs == 0 )); then
        echo "No job for this array task id: $SLURM_ARRAY_TASK_ID"
        exit 0
    fi

    (( line_end = line_start + njobs - 1 ))

    echo nlines=$nlines, njobs=$njobs, line_start=$line_start, line_end=$line_end

    while read -r path direction; do
        if [[ ! -e $path ]]; then
            echo "Warning! $path does not exist, skip it"
            continue
        fi
        if [[ $direction != "x" && $direction != "y" && $direction != "z" ]]; then
            echo "Error! direction $direction is not x, y, or z, skip it"
            continue
        fi

        for mat_line in "${material_lines[@]}"; do
            read -r young_module yield_stress <<< "$mat_line"
            echo ">>> Running: $path $direction with E=$young_module, Y=$yield_stress"
            cal_job $path $direction
        done
        
        # 收集这个 STP 文件的所有方向结果
        for mat_line in "${material_lines[@]}"; do
            read -r young_module yield_stress <<< "$mat_line"
            collect_results "$path" "$young_module" "$yield_stress"
        done

    done < <(sed -n "${line_start},${line_end}p" $infile)

else
    echo ">>> Load balancing mode enabled."

    lockfile=".lock.$SLURM_ARRAY_JOB_ID"
    countfile=".curid.$SLURM_ARRAY_JOB_ID"
    readarray -t tasks < "$infile"

    function getjob(){
        (
            flock -x 9
            curid=$(<$countfile)
            curid=${curid:-0}
            jobdef=${tasks[$curid]}
            if [ -n "$jobdef" ]; then
                (( curid++ ))
                echo "$curid" > $countfile
                echo "$jobdef"
            fi
        ) 9>"$lockfile"
    }

    count=0
    while true; do
        jobdef=$(getjob)
        [ -z "$jobdef" ] && break

        echo "($(date +%H:%M:%S)) [Task $SLURM_ARRAY_TASK_ID] process: $jobdef"

        read -r path direction <<< "$jobdef"

        for mat_line in "${material_lines[@]}"; do
            read -r young_module yield_stress <<< "$mat_line"
            echo ">>> Running: $path $direction with E=$young_module, Y=$yield_stress"
            cal_job $path $direction
        done

        ((count++))
    done

    echo "Total: $count jobs executed."
fi
