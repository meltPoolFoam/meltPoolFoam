#!/bin/bash
#=============================================================================
# run_vertical_solidification.sh
#
# Usage:
#   ./run_vertical_solidification.sh [--sbatch | --manual]
#
# Description:
#   Copies the case into _verticalSolidification2D/ and runs it
#   either manually (background) or via SLURM.
#=============================================================================

set -e

# ========================== CONFIGURATION ==================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/_verticalSolidification2D"
OPENFOAM_MODULE="openfoam/v2406"
WALLTIME="48:00:00"
PARTITION="amd,intel"
JOB_NAME="vert_solid"

# Run mode: "sbatch" or "manual" (default: manual)
RUN_MODE="manual"

# Parse command-line arguments
if [[ "$1" == "--sbatch" ]]; then
    RUN_MODE="sbatch"
elif [[ "$1" == "--manual" ]]; then
    RUN_MODE="manual"
fi

# ========================== SETUP ==========================================

# Copy the case into a run directory if it does not exist
if [ -d "$RUN_DIR" ]; then
    echo "ERROR: ${RUN_DIR} already exists. Remove it to re-run." >&2
    exit 1
fi

mkdir -p "$RUN_DIR"
for item in 0 Allclean Allrun constant system; do
    cp -r "${SCRIPT_DIR}/${item}" "${RUN_DIR}/"
done
echo "Copied case to ${RUN_DIR}"

CASE_DIR="$RUN_DIR"

# Parse numberOfSubdomains from decomposeParDict
NCORES=$(grep 'numberOfSubdomains' "${CASE_DIR}/system/decomposeParDict" \
    | awk '{print $2}' | tr -d ';')

if [ -z "$NCORES" ] || [ "$NCORES" -lt 1 ] 2>/dev/null; then
    echo "ERROR: could not parse numberOfSubdomains from decomposeParDict" >&2
    exit 1
fi

# ========================== MAIN ===========================================

echo "============================================================"
echo " Vertical Solidification Case Runner"
echo "============================================================"
echo " Case directory : ${CASE_DIR}"
echo " Cores          : ${NCORES}"
echo " Wall time      : ${WALLTIME}"
echo " Run mode       : ${RUN_MODE}"
echo "============================================================"

if [[ "${RUN_MODE}" == "sbatch" ]]; then

    # ---------- SLURM submission ----------
    SLURM_SCRIPT="${CASE_DIR}/job_${JOB_NAME}.sh"

    cat > "${SLURM_SCRIPT}" << SLURM_EOF
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --partition=${PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=${NCORES}
#SBATCH --time=${WALLTIME}
#SBATCH --output=${JOB_NAME}_%j.out
#SBATCH --error=${JOB_NAME}_%j.err

module purge
module load ${OPENFOAM_MODULE}

cd "${CASE_DIR}"

echo "Starting vertical solidification (nprocs=${NCORES})"
date

./Allrun -parallel

echo "Simulation complete."
date
SLURM_EOF

    JOB_ID=$(sbatch "${SLURM_SCRIPT}" | awk '{print $4}')
    echo "Submitted vertical solidification: Job ID ${JOB_ID}"
    echo "Monitor with: squeue -u \$USER"

elif [[ "${RUN_MODE}" == "manual" ]]; then

    # ---------- Manual (local) run ----------
    echo "  Running ./Allrun -parallel ..."
    cd "${CASE_DIR}"
    ./Allrun -parallel

fi

echo ""
echo " Done."
