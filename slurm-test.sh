#!/bin/bash
#SBATCH --job-name=plastic-board
#SBATCH -N 1
#SBATCH -n 8
#SBATCH --partition=operation
#SBATCH -t 01:00:00

##SBATCH --mem=800GB
##SBATCH -o %x_%j.log

### Configure environment variables, need to unset SLURM's Global Task ID for ABAQUS's PlatformMPI to work
### Create ABAQUS environment file for current job, you can set/add your own options (Python syntax)

module purge
module add abaqus/2022
export I_MPI_PMI_LIBRARY=/opt/gridview/slurm/lib/libpmi2.so
module load compiler/intel/2021.3.0 mpi/intelmpi/2021.3.0
ulimit -s unlimited


# Default parameters (can be overridden by environment variables)
INFILE=${PLASIM_INFILE:-"/public/home/nieqi01/zrx/20260310abq-pla/stp/3x3x3_0.8/Array_3x3x3_S4_D8_12_12_12.step"}
__scriptdir__=${SLURM_SUBMIT_DIR:-$(pwd)}
OUTDIR=${PLASIM_OUTDIR:-"$(dirname $__scriptdir__)/res-test"}
DIRECTION=${PLASIM_DIRECTION:-"z"}
NCPU=${PLASIM_NCPU:-"1"}
CHECK_INTERVAL=${PLASIM_CHECK_INTERVAL:-"60"}
EARLYSTOP=${PLASIM_EARLYSTOP:--e}
DEBUG=${PLASIM_DEBUG:-}
YOUNG_MODULE=${PLASIM_YOUNG_MODULE:-"28700"}
POISSON_RATIO=${PLASIM_POISSON_RATIO:-"0.3"}
YIELD_STRESS=${PLASIM_YIELD_STRESS:-"221.0"}
DENSITY=${PLASIM_ROU:-"2.7e-09"}

./run-plastic-board.sh -i "$INFILE" -o "$OUTDIR" -"$DIRECTION" -c "$CHECK_INTERVAL" -n "$NCPU" "$EARLYSTOP" \
    -E "$YOUNG_MODULE" -P "$POISSON_RATIO" -Y "$YIELD_STRESS" -R "$DENSITY"
