#!/bin/bash
#SBATCH -J plastic-board-batch
#SBATCH -p operation
#SBATCH -t 60:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=2
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
if [[ ! -e "$result_csv" ]]; then
    echo "stp_file,young_module,yield_stress,direction,sim_yield_force,sim_yield_strength" > "$result_csv"
fi



function cal_job(){
    path=$1
    direction=$2

    bname=$(basename $path)
    pbname=${bname%.*}  # remove suffix extension

    stp_filename=$(basename $path)
    stp_filename=${stp_filename%.*}

    # run-plastic-board.sh creates: outdir/model.direction/stp_EYoung_Yyield_direction/
    # and CSV file: stp_EYoung_Yyield_direction.csv inside that folder
    model_dir="${outdir}/${pbname}.${direction}"
    work_dir="${model_dir}/${stp_filename}_E${young_module}_Y${yield_stress}_${direction}"
    csv_file="${stp_filename}_E${young_module}_Y${yield_stress}_${direction}.csv"
    failed_csv_file="${stp_filename}_E${young_module}_Y${yield_stress}_${direction}_failed.csv"

    if [[ -e $work_dir/$csv_file || -e $work_dir/$failed_csv_file ]]; then
        echo "sbatch.sh: result csv already exists in $work_dir, skip it"
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

    timeout $timelimit $roscript -i $path -o $model_dir -${direction} -c 120 -n 1 -e \
        -E $young_module -P $poisson_ration -Y $yield_stress -R $density >& $model_dir/during.log
    if [[ $? -eq 124 ]]; then
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
    fi

    # Append to result.csv
    sim_yield_force=""
    sim_yield_strength=""
    result_work_csv="$work_dir/$csv_file"
    if [[ -e "$result_work_csv" ]]; then
        yield_line=$(grep "^#.*YIELD_FORCE_N=" "$result_work_csv" | head -1)
        if [[ -n "$yield_line" ]]; then
            sim_yield_force=$(echo "$yield_line" | sed 's/.*YIELD_FORCE_N=\([^,]*\).*/\1/' | tr -d ' ')
            if [[ "$sim_yield_force" != "Not_Reached" ]]; then
                area_a0=$(echo "$yield_line" | sed 's/.*AREA_A0=\([0-9.]*\).*/\1/' | tr -d ' ')
                if [[ -n "$area_a0" && "$area_a0" != "0" ]]; then
                    sim_yield_strength=$(awk "BEGIN {printf \"%.4f\", $sim_yield_force / $area_a0}")
                fi
            fi
        fi
    fi
    echo "$stp_filename,$young_module,$yield_stress,$direction,$sim_yield_force,$sim_yield_strength" >> "$result_csv"

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
