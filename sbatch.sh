#!/bin/bash
#SBATCH -J plastic-board-batch
#SBATCH -p operation
#SBATCH -t 60:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --array=0-999
#SBATCH -o slurm.logs/log_%A_%a.txt

usage() {
    exitcode=$1
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --help              Show this help message
  -i, --infile FILE       Input file
      --infile=FILE
  -s, --srcdir DIR        Source directory (default: current directory)
      --srcdir=DIR
  -o, --outdir DIR        Output directory
      --outdir=DIR
  -r, --roscript SCRIPT   Script to run (default: run-plastic-board.sh)
      --roscript=SCRIPT
  -l, --loadBalance       Enable load balancing mode
  -E, --young MODULE      Young's modulus in MPa (default: 28700)
      --young=MODULE
  -P, --poisson RATIO     Poisson's ratio (default: 0.3)
      --poisson=RATIO
  -Y, --yield STRESS      Yield strength in MPa (default: 221.0)
      --yield=STRESS
  -R, --density DENSITY   Density in t/mm3 (default: 2.7e-09)
      --density=DENSITY

Examples:
  $(basename "$0") -i data.txt -o results
  $(basename "$0") --infile data.txt --outdir results --young 28700 --yield 221.0
EOF
    exit "$exitcode"
}


curdir=$PWD

module purge
module add abaqus/2022
export I_MPI_PMI_LIBRARY=/opt/gridview/slurm/lib/libpmi2.so
module load compiler/intel/2021.3.0 mpi/intelmpi/2021.3.0
ulimit -s unlimited



infile=
outdir=
roscript=
loadBalance=
srcdir=
timelimit=1h
young_module=28700
poisson_ration=0.3
yield_stress=221.0
density=2.7e-09

while getopts ":hli:o:r:s:t:E:P:Y:R:-:" opt; do
    case $opt in
        h) usage 0 ;;
        i) infile="$OPTARG" ;;
        o) outdir="$OPTARG" ;;
        r) roscript="$OPTARG" ;;
        l) loadBalance=1 ;;
        s) srcdir="$OPTARG" ;;
        t) timelimit="$OPTARG" ;;
        E) young_module="$OPTARG" ;;
        P) poisson_ration="$OPTARG" ;;
        Y) yield_stress="$OPTARG" ;;
        R) density="$OPTARG" ;;
        -)
            case $OPTARG in
                help) usage 0 ;;

                infile)
                    infile="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                infile=*)
                    infile="${OPTARG#*=}"
                    ;;

                outdir)
                    outdir="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                outdir=*)
                    outdir="${OPTARG#*=}"
                    ;;

                roscript)
                    roscript="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                roscript=*)
                    roscript="${OPTARG#*=}"
                    ;;
                loadBalance)
                    loadBalance=1
                    ;;
                srcdir)
                    srcdir="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                srcdir=*)
                    srcdir="${OPTARG#*=}"
                    ;;
                timelimit)
                    timelimit="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                timelimit=*)
                    timelimit="${OPTARG#*=}"
                    ;;
                young)
                    young_module="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                young=*)
                    young_module="${OPTARG#*=}"
                    ;;
                poisson)
                    poisson_ration="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                poisson=*)
                    poisson_ration="${OPTARG#*=}"
                    ;;
                yield)
                    yield_stress="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                yield=*)
                    yield_stress="${OPTARG#*=}"
                    ;;
                density)
                    density="${!OPTIND}"
                    OPTIND=$((OPTIND+1))
                    ;;
                density=*)
                    density="${OPTARG#*=}"
                    ;;
                *)
                    echo "Unknown option --$OPTARG"
                    usage 1
                    ;;
            esac ;;
        :)
            echo "Option -$OPTARG requires an argument"
            usage 1
            ;;
        \?)
            echo "Unknown option -$OPTARG"
            usage 1
            ;;
    esac
done
shift $((OPTIND-1))

scriptG=${srcdir:-.}/get-standard-pid.sh


echo ">>> infile=$infile"
echo ">>> srcdir=$srcdir"
echo ">>> outdir=$outdir"
echo ">>> roscript=$roscript"
echo ">>> loadBalance=$loadBalance"
echo ">>> timelimit=$timelimit"
echo ">>> young_module=$young_module"
echo ">>> poisson_ration=$poisson_ration"
echo ">>> yield_stress=$yield_stress"
echo ">>> density=$density"
echo ">>> scriptG=$scriptG"

if [[ ! -e "$infile" || -z "$outdir" || ! -e "$roscript" || ! -e "$scriptG" ]]; then
    usage 1
fi


mkdir -p $outdir
mkdir -p slurm.logs



function cal_job(){
    path=$1
    direction=$2

    bname=$(basename $path)
    pbname=${bname%.*}  # remove suffix extension

    stp_filename=$(basename $path)
    stp_filename=${stp_filename%.*}

    # Final work directory: outdir/pbname.direction/stp_EYoung_Yyield_direction/
    work_dir="${outdir}/${pbname}.${direction}/${stp_filename}_E${young_module}_Y${yield_stress}_${direction}"
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

    outdirC=${outdir}/${pbname}.${direction}
    mkdir -p $outdirC

    if [[ -e ${outdirC2}/abaqusError || -e ${outdirC3}/abaqusError ]]; then
        echo "sbatch.sh: abaqusError exists in ${outdirC2} or ${outdirC3}, skip $path $direction"
        touch $outdirC/abaqusError
        return
    fi

    if [[ -e ${outdirC2}/timeoutNote || -e ${outdirC3}/timeoutNote ]]; then
        echo "sbatch.sh: timeoutNote exists in ${outdirC2} or ${outdirC3}, skip $path $direction"
        touch $outdirC/timeoutNote
        return
    fi

    if [[ -e ${outdirC2}/skipNote || -e ${outdirC3}/skipNote ]]; then
        echo "sbatch.sh: skipNote exists in ${outdirC2} or ${outdirC3}, skip $path $direction"
        touch $outdirC/skipNote
        return
    fi

    timeout $timelimit $roscript -i $path -o $outdirC -${direction} -c 120 -n 2 -e \
        -E $young_module -P $poisson_ration -Y $yield_stress -R $density >& $outdirC/during.log
    if [[ $? -eq 124 ]]; then
        echo "Warning! timeout for $path $direction, killing all related processed ..."
        touch $outdirC/timeoutNote
        timeout_csv="${stp_filename}_E${young_module}_Y${yield_stress}_timeout.csv"
        echo "Error: Simulation timeout" > $outdirC/$timeout_csv
        psline=$($scriptG $outdirC)
        if [[ -n "$psline" ]]; then
            pid=$(echo $psline | awk '{print $1}')
            echo "   - Simulation timeout, killing process $pid"
            kill -9 $pid
        fi
        sleep 5
        cd $outdirC
        rm -rf *.odb *.stt *.mdl *.prt *.simdir
        rm -rf Job-Compression-Run.* *.sat *.py *.rec abaqusis.env abaqus_acis.log abaqus1.rec
        cd $curdir
    fi

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

        cal_job $path $direction

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

        cal_job $path $direction

        ((count++))
    done

    echo "Total: $count jobs executed."
fi
