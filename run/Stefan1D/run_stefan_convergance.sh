#!/bin/bash
#=============================================================================
# run_stefan_convergence.sh
#
# Usage:
#   ./run_stefan_convergance.sh [--sbatch | --manual]
#
# Description:
#   Creates 1D_stefan{N} folders for each mesh resolution, copies base case,
#   modifies blockMeshDict, runs simulations, and generates convergence plots.
#
#   All artifacts live inside _stefan_convergance/ so they don't clutter
#   the source case directory.
#
#   deltaT is the same for all resolutions (inherited from base case).
#   All cases run serial.
#=============================================================================

set -e

# ========================== CONFIGURATION ==================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/_stefan_convergance"
OPENFOAM_MODULE="openfoam/v2406"

RESOLUTIONS=(16 32 64 128)

WALLTIME="24:00:00"
PARTITION="amd,intel"

# Run mode: "sbatch" or "manual" (default: manual)
RUN_MODE="manual"

if [[ "$1" == "--sbatch" ]]; then
    RUN_MODE="sbatch"
elif [[ "$1" == "--manual" ]]; then
    RUN_MODE="manual"
fi

# ========================== SETUP ==========================================

if [ -d "$WORK_DIR" ]; then
    echo "ERROR: ${WORK_DIR} already exists. Remove it to re-run." >&2
    exit 1
fi

mkdir -p "$WORK_DIR"

echo "============================================="
echo " Stefan 1D Convergence Study"
echo "============================================="
echo " Work directory  : ${WORK_DIR}"
echo " Resolutions     : ${RESOLUTIONS[*]}"
echo " Run mode        : ${RUN_MODE}"
echo "============================================="

# ---------- Step 1: Create folders and modify files ----------

for N in "${RESOLUTIONS[@]}"; do
    CASE_DIR="${WORK_DIR}/1D_stefan${N}"
    echo ""
    echo "  Setting up: 1D_stefan${N}"

    mkdir -p "${CASE_DIR}"
    for item in 0 Allclean Allrun constant system; do
        cp -r "${SCRIPT_DIR}/${item}" "${CASE_DIR}/"
    done

    # ---- Modify blockMeshDict: cell count (N 1 1) ----
    BLOCKMESHDICT="${CASE_DIR}/system/blockMeshDict"
    sed -i -E "s/\([[:space:]]*[0-9]+[[:space:]]+1[[:space:]]+1[[:space:]]*\)/(${N} 1 1)/g" "${BLOCKMESHDICT}"

    # deltaT is intentionally the same for all resolutions

    echo "    cells=(${N} 1 1)"
done

# ---------- Step 2: Run simulations ----------

echo ""
echo "============================================="
echo " Running simulations (mode: ${RUN_MODE})"
echo "============================================="

if [[ "${RUN_MODE}" == "sbatch" ]]; then

    JOB_IDS=()

    for N in "${RESOLUTIONS[@]}"; do
        CASE_DIR="${WORK_DIR}/1D_stefan${N}"
        LABEL="stefan_${N}"

        cat > "${CASE_DIR}/slurm_run.sh" << EOFSLURM
#!/bin/bash
#SBATCH --job-name=${LABEL}
#SBATCH --partition=${PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=${WALLTIME}
#SBATCH --output=slurm_%j.out
#SBATCH --error=slurm_%j.err

module purge
module load ${OPENFOAM_MODULE}

cd "${CASE_DIR}"

echo "Starting ${LABEL} (N=${N})"
date

./Allrun

echo "Simulation complete: ${LABEL}"
date
EOFSLURM

        JOB_ID=$(sbatch "${CASE_DIR}/slurm_run.sh" | awk '{print $4}')
        JOB_IDS+=("$JOB_ID")
        echo "  Submitted ${LABEL}: Job ID ${JOB_ID}"
    done

    # Submit post-processing job depending on all simulations
    ALL_JOB_IDS=$(IFS=:; echo "${JOB_IDS[*]}")

    cat > "${WORK_DIR}/slurm_postprocess.sh" << EOFPP
#!/bin/bash
#SBATCH --job-name=stefan_pp
#SBATCH --partition=${PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=01:00:00
#SBATCH --output=slurm_pp_%j.out
#SBATCH --error=slurm_pp_%j.err

cd "${WORK_DIR}"

echo "Running Stefan convergence analysis..."
date

module load python
ROOT_DIR="${WORK_DIR}" python3 ${SCRIPT_DIR}/stefan_convergence_analysis.py

echo "Post-processing complete."
date
EOFPP

    PP_JOB_ID=$(sbatch --dependency=afterok:${ALL_JOB_IDS} \
        "${WORK_DIR}/slurm_postprocess.sh" | awk '{print $4}')
    echo ""
    echo "Submitted post-processing: Job ID ${PP_JOB_ID}"
    echo ""
    echo "============================================"
    echo "All jobs submitted. Summary:"
    echo "============================================"
    echo "Simulation Job IDs: ${JOB_IDS[*]}"
    echo "Post-processing Job ID: ${PP_JOB_ID}"
    echo "Monitor with: squeue -u \$USER"

elif [[ "${RUN_MODE}" == "manual" ]]; then

    for N in "${RESOLUTIONS[@]}"; do
        CASE_DIR="${WORK_DIR}/1D_stefan${N}"
        echo "  Running 1D_stefan${N}..."

        cd "${CASE_DIR}"
        ./Allrun
        cd "${WORK_DIR}"

        echo "  Finished 1D_stefan${N}"
    done

    # ---------- Run Python analysis ----------
    echo ""
    echo "Running Stefan convergence analysis..."
    ROOT_DIR="${WORK_DIR}" python3 "${SCRIPT_DIR}/stefan_convergence_analysis.py"

    echo ""
    echo "All done!"
fi
