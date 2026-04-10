#!/bin/bash
#
# SLURM run script — singleTrackPrinting
#
# Usage: cd run/singleTrackPrinting && ./run_sbatch.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/_singleTrackPrinting"
OPENFOAM_MODULE="openfoam/v2406"

# Copy the case into a run directory if it does not exist
if [ ! -d "$RUN_DIR" ]; then
    mkdir -p "$RUN_DIR"
    for item in 0 Allclean Allrun constant system; do
        cp -r "${SCRIPT_DIR}/${item}" "${RUN_DIR}/"
    done
    echo "Copied case to ${RUN_DIR}"
fi

CASE_DIR="$RUN_DIR"

# Parse numberOfSubdomains from decomposeParDict
NPROCS=$(grep 'numberOfSubdomains' "${CASE_DIR}/system/decomposeParDict" \
    | awk '{print $2}' | tr -d ';')

if [ -z "$NPROCS" ] || [ "$NPROCS" -lt 1 ] 2>/dev/null; then
    echo "ERROR: could not parse numberOfSubdomains from decomposeParDict" >&2
    exit 1
fi

cat > "${CASE_DIR}/slurm_run.sh" << EOFSLURM
#!/bin/bash
#SBATCH --job-name=singleTrackPrinting
#SBATCH --partition=amd,intel
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=${NPROCS}
#SBATCH --time=48:00:00
#SBATCH --output=slurm_%j.out
#SBATCH --error=slurm_%j.err

module purge
module load ${OPENFOAM_MODULE}

cd "${CASE_DIR}"

echo "Starting singleTrackPrinting (nprocs=${NPROCS})"
date

./Allrun -parallel

echo "Simulation complete."
date
EOFSLURM

JOB_ID=$(sbatch "${CASE_DIR}/slurm_run.sh" | awk '{print $4}')
echo "Submitted singleTrackPrinting: Job ID ${JOB_ID}"
echo "Monitor with: squeue -u \$USER"
