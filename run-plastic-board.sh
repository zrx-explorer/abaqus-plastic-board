#!/bin/bash


# This script serves as a wrapper for running plastic-board-abq.py.
# Maintainer: Zhang Ruixuan
#
# ---------------------------------------------------------
# 2026-03-10  Adapted from run-plaSim-abaqus.sh for board simulation

__filedir__=$(dirname $(readlink -f "${BASH_SOURCE[0]}"))
echo "__filedir__=$__filedir__"


function help(){
    echo "[~] Usage"
    echo "  - run-plastic-board.sh <options>"
    echo ""
    echo "Options:"
    echo "  -h          Show this help message"
    echo "  -i <file>   Input STP file for simulation (required)"
    echo "  -o <dir>    Output directory for results (default: current directory)"
    echo "  -x          Run simulation in x-direction (default)"
    echo "  -y          Run simulation in y-direction"
    echo "  -z          Run simulation in z-direction"
    echo "  -n <val>    Number of CPUs to use (default: 1)"
    echo "  -c <val>    Check interval, seconds (default: 60)"
    echo "  -s <val>    Script file to run (default: plastic-board-abq.py in the same directory)"
    echo "  -d          Enable debug mode, will keep all files"
    echo "  -e          Enable earlyStop mode"
    echo "  -E <val>    Young's modulus in MPa (default: 28700)"
    echo "  -P <val>    Poisson's ratio (default: 0.3)"
    echo "  -Y <val>    Yield strength in MPa (default: 221.0)"
    echo "  -R <val>    Density in t/mm3 (default: 2.7e-09)"

}

script=${__filedir__}/plastic-board-abq.py
scriptM=${__filedir__}/monitor.py
scriptG=${__filedir__}/get-standard-pid.sh

check_interval=60
earlyStop=0
debug=0
young_module=28700
poisson_ration=0.3
yield_stress=221.0
density=2.7e-09
while getopts "hi:o:xyzn:c:s:defE:P:Y:R:" opt; do
    case $opt in
        h)
            help
            exit 0
            ;;
        i)
            export PLASIM_INFILE=$(realpath "$OPTARG")
            ;;
        o)
            export PLASIM_OUTDIR=$(realpath -m "$OPTARG")
            ;;
        x|y|z)
            export PLASIM_DIRECTION="$opt"
            ;;
        n)
            export PLASIM_NCPUS="$OPTARG"
            ;;
        d)
            debug=1
            ;;
        e)
            earlyStop=1
            ;;
        c)
            check_interval="$OPTARG"
            ;;
        s)
            script=$(realpath "$OPTARG")
            ;;
        E)
            young_module="$OPTARG"
            ;;
        P)
            poisson_ration="$OPTARG"
            ;;
        Y)
            yield_stress="$OPTARG"
            ;;
        R)
            density="$OPTARG"
            ;;
        ?)
            help
            exit 1
            ;;
    esac
done
shift $(($OPTIND - 1))
export PLASIM_DEBUG=$debug
export PLASIM_YOUNG_MODULE=$young_module
export PLASIM_POISSON_RATIO=$poisson_ration
export PLASIM_YIELD_STRESS=$yield_stress
export PLASIM_ROU=$density


if [[ ! -e $script ]]; then
    echo "Error! Script file $script does not exist!"
    echo '------------------------------------------'
    help
    exit 103
fi


if [[ ! -e $PLASIM_INFILE ]]; then
    echo "Error! PLASIM_INFILE ($PLASIM_INFILE) does not exist!"
    echo '------------------------------------'
    help
    exit 101
fi

if [[ "$PLASIM_DIRECTION" != x && "$PLASIM_DIRECTION" != y && "$PLASIM_DIRECTION" != z ]]; then
    echo "Error! PLASIM_DIRECTION must be one of x, y or z, now is $PLASIM_DIRECTION"
    echo '--------------------------------------------------------------------------'
    help
    exit 102
fi

if ! which abq2022 >& /dev/null; then
    echo 'Abaqus module not loaded, load it inside this script'
    module purge
    module add abaqus/2022
    export I_MPI_PMI_LIBRARY=/opt/gridview/slurm/lib/libpmi2.so
    module load compiler/intel/2021.3.0 mpi/intelmpi/2021.3.0
    ulimit -s unlimited
fi

# Get STP basename for folder naming
stp_basename=$(basename "$PLASIM_INFILE")
stp_basename="${stp_basename%.*}"  # Remove extension

# Create final work directory: outdir/stp_EYoung_Yyield_direction/
yield_folder="${stp_basename}_E${young_module}_Y${yield_stress}_${PLASIM_DIRECTION}"
work_dir="$PLASIM_OUTDIR/$yield_folder"
mkdir -p "$work_dir"
cd "$work_dir"

# Create info.json in the work directory
cat > info.json << EOF
{
    "stp_filename": "$(basename $PLASIM_INFILE)",
    "direction": "$PLASIM_DIRECTION",
    "ncpus": "$PLASIM_NCPUS",
    "start_time": $(date +%s),
    "validStep": 0,
    "young_module": $young_module,
    "poisson_ration": $poisson_ration,
    "yield_stress": $yield_stress
}
EOF

abq2022 cae noGUI=$script &

if [[ $earlyStop == 1 ]]; then
    echo "run-plastic-board.sh: Early stop mode enabled, monitoring odb file ..."
    errCount=0
    checkCount=0
    while :; do
        sleep $check_interval

        if [[ -z "$(jobs -r)" ]]; then
            echo "run-plastic-board.sh: abaqus computation process is finished, exiting monitoring loop"
            break
        fi

        (( checkCount++ ))
        if [[ ! -e "Job-Compression-Run.odb" ]]; then
            continue
        fi
        
        abq2022 python $scriptM
        mstat=$?
        psline=$($scriptG $PWD)
        if [[ $mstat == 0 ]]; then
            if [[ -n "$psline" ]]; then
                pid=$(echo $psline | awk '{print $1}')
                echo "run-plastic-board.sh: Simulation finished, killing process $pid"
                kill %1
                kill -9 $pid
            fi
            break
        elif [[ $mstat == 1 ]]; then
            (( errCount = 0 ))
            continue
        else
            (( errCount++ ))
            if (( errCount > 3 )); then
                echo "run-plastic-board.sh: Unexpected exit code of $scriptM, exiting monitoring loop"
                if [[ -n "$psline" ]]; then
                    pid=$(echo $psline | awk '{print $1}')
                    echo "run-plastic-board.sh: Simulation error, killing process $pid"
                    kill %1
                    kill -9 $pid
                fi
                break
            fi
        fi
    done
fi

fg
sleep 10

# CSV filenames
csv_name="${stp_basename}_E${young_module}_Y${yield_stress}_${PLASIM_DIRECTION}.csv"
failed_csv_name="${stp_basename}_E${young_module}_Y${yield_stress}_${PLASIM_DIRECTION}_failed.csv"

if [[ -e skipNote ]]; then
    echo 
    echo "run-plastic-board.sh: Task with too many elements or warning elements, skip it"
    echo 
    echo "Error: Task skipped due to too many elements or warning elements" > $failed_csv_name
    rm -f *.sat
    exit
fi

abq2022 python $scriptM

errMSG="$(grep '\*\*\* *ERROR' Job-Compression-Run.msg 2>/dev/null)"
if [[ -n "$errMSG" ]]; then
    echo 
    echo "run-plastic-board.sh: Error! Abaqus error detected:"
    echo -e "$errMSG"
    echo
    touch abaqusError
    echo "Error: Abaqus computation failed" > $failed_csv_name
    echo "$errMSG" >> $failed_csv_name
    if [[ $debug == 0 ]]; then
        # Keep only .odb and .cae, remove other files
        find . -type f ! -name "*.odb" ! -name "*.cae" ! -name "*.csv" ! -name "info.json" -delete
    fi
    exit
fi

if [[ $debug == 1 ]]; then
    echo "run-plastic-board.sh: Debug mode enabled, not removing any files"
    exit
fi

if [[ -e "$csv_name" ]]; then
    echo "run-plastic-board.sh: Success! Removing intermediate files"
    # Remove all Abaqus intermediate files, keep only CSV and info.json
    rm -rf *.odb *.stt *.mdl *.prt *.simdir
    rm -rf Job-Compression-Run.* *.sat *.py *.rec abaqusis.env abaqus_acis.log abaqus1.rec
    rm -f newU.npy surfW.off boundaryNodes.npy
    rm -f *.log *.msg *.sta *.res
else
    echo "run-plastic-board.sh: Warning! CSV file not found"
    # Cleanup anyway
    rm -rf *.odb *.stt *.mdl *.prt *.simdir
    rm -rf Job-Compression-Run.* *.sat *.py *.rec abaqusis.env abaqus_acis.log abaqus1.rec
    rm -f newU.npy surfW.off boundaryNodes.npy
fi
