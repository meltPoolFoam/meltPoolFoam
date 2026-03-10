
#!/bin/bash
#=============================================================================
# run_vertical_solidification.sh
#
# Usage:
#   ./run_vertical_solidification.sh [--sbatch | --manual]
#
# Description:
#   Runs the vertical solidification OpenFOAM case in the current directory
#   either manually (background) or via SLURM, using 16 cores and a
#   48-hour time limit. No mesh convergence, no modifications — just runs.
#=============================================================================

set -e

# ========================== CONFIGURATION ==================================

CASE_DIR="$(pwd)"
NCORES=16
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
#SBATCH --ntasks=${NCORES}
#SBATCH --time=${WALLTIME}
#SBATCH --output=${JOB_NAME}_%j.out
#SBATCH --error=${JOB_NAME}_%j.err

module purge
module load openfoam/v2406

cd ${CASE_DIR}

## Run the vertical solidification case
./Allrun -parallel
SLURM_EOF

    chmod +x "${SLURM_SCRIPT}"
    echo "  Submitting SLURM job..."
    sbatch "${SLURM_SCRIPT}"

    echo ""
    echo "============================================================"
    echo " Vertical solidification job submitted to SLURM."
    echo " Monitor with: squeue -u \$USER"
    echo "============================================================"

elif [[ "${RUN_MODE}" == "manual" ]]; then

    # ---------- Manual (local) run ----------
    echo "  Loading OpenFOAM module..."

    echo "  Running ./Allrun -parallel ..."
    cd "${CASE_DIR}"
    ./Allrun -parallel > log.Allrun 2>&1 &
    PID=$!
    echo "  PID: ${PID}"

    echo ""
    echo "============================================================"
    echo " Waiting for vertical solidification to complete"
    echo " (PID: ${PID})..."
    echo "============================================================"

    wait ${PID}
    EXIT_CODE=$?

    if [ ${EXIT_CODE} -eq 0 ]; then
        echo "  Vertical solidification completed successfully."
    else
        echo "  WARNING: Simulation exited with code ${EXIT_CODE}!"
    fi

fi

echo ""
echo " Done."
