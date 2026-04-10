#!/bin/bash
#=============================================================================
# run_horizontal_solidification_convergence.sh
#
# Usage:
#   ./run_hor_sol_convergance.sh [--sbatch | --manual]
#
# Description:
#   Creates horiz_solid_{corr|nocorr}_{N} folders for each mesh resolution
#   and tau correction case, copies base case, modifies blockMeshDict and
#   controlDict, runs simulations, and generates convergence plots of
#   relative mass error vs time.
#
#   All artifacts live inside _horiz_sol_convergance/ so they don't
#   clutter the source case directory.
#
#   All cases run serial except N=256 which runs in parallel.
#=============================================================================

set -e

# ========================== CONFIGURATION ==================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/_horiz_sol_convergance"
OPENFOAM_MODULE="openfoam/v2406"

RESOLUTIONS=(16 32 64 128 256)
PARALLEL_THRESHOLD=256

# Two tau correction cases
TAU_CASES=("corr" "nocorr")
declare -A TAU_VALUES
TAU_VALUES["corr"]="USE_DELTAT"
TAU_VALUES["nocorr"]="1e10"

# Base deltaT for N=16 cells
BASE_DELTAT="2e-4"
BASE_N=16

WALLTIME="48:00:00"
PARTITION="amd,intel"

# Run mode: "sbatch" or "manual" (default: manual)
RUN_MODE="manual"

if [[ "$1" == "--sbatch" ]]; then
    RUN_MODE="sbatch"
elif [[ "$1" == "--manual" ]]; then
    RUN_MODE="manual"
fi

# ========================== FUNCTIONS ======================================

compute_deltaT() {
    local N=$1
    python3 -c "
ratio = (${BASE_N} / ${N}) ** 2
dt = ratio * ${BASE_DELTAT}
print(f'{dt:.6e}')
"
}

# ========================== SETUP ==========================================

if [ -d "$WORK_DIR" ]; then
    echo "ERROR: ${WORK_DIR} already exists. Remove it to re-run." >&2
    exit 1
fi

mkdir -p "$WORK_DIR"

echo "============================================================"
echo " Horizontal Solidification 2D Convergence Study"
echo " (tau correction ON vs OFF)"
echo "============================================================"
echo " Work directory  : ${WORK_DIR}"
echo " Resolutions     : ${RESOLUTIONS[*]}"
echo " Tau cases       : ${TAU_CASES[*]}"
echo " Run mode        : ${RUN_MODE}"
echo "============================================================"

# ---------- Step 1: Create folders and modify files ----------

for TAU_CASE in "${TAU_CASES[@]}"; do
    for N in "${RESOLUTIONS[@]}"; do
        CASE_DIR="${WORK_DIR}/horiz_solid_${TAU_CASE}_${N}"
        echo ""
        echo "  Setting up: horiz_solid_${TAU_CASE}_${N}"

        mkdir -p "${CASE_DIR}"
        for item in 0 Allclean Allrun constant system; do
            cp -r "${SCRIPT_DIR}/${item}" "${CASE_DIR}/"
        done

        # ---- Modify blockMeshDict ----
        BLOCKMESHDICT="${CASE_DIR}/system/blockMeshDict"
        sed -i -E "s/\([[:space:]]*[0-9]+[[:space:]]+1[[:space:]]+[0-9]+[[:space:]]*\)/(${N} 1 ${N})/g" "${BLOCKMESHDICT}"

        # ---- Modify controlDict ----
        CONTROLDICT="${CASE_DIR}/system/controlDict"
        DELTAT=$(compute_deltaT ${N})
        sed -i -E "s/^(deltaT[[:space:]]+)[^;]+;/\1${DELTAT};/" "${CONTROLDICT}"

        # ---- Modify tauCorr ----
        TAU_VAL="${TAU_VALUES[${TAU_CASE}]}"
        if [[ "${TAU_VAL}" == "USE_DELTAT" ]]; then
            TAU_VAL="${DELTAT}"
        fi

        TRANSPORT_PROPS="${CASE_DIR}/constant/transportProperties"
        if [ -f "${TRANSPORT_PROPS}" ] && grep -q "tauCorr" "${TRANSPORT_PROPS}"; then
            sed -i -E "s/^([[:space:]]*tauCorr[[:space:]]+)[^;]+;/\1${TAU_VAL};/" "${TRANSPORT_PROPS}"
        fi

        echo "    cells=(${N} 1 ${N}) | dt=${DELTAT} | tauCorr=${TAU_VAL}"
    done
done

# ---------- Step 2: Run simulations ----------

echo ""
echo "============================================================"
echo " Running simulations (mode: ${RUN_MODE})"
echo "============================================================"

if [[ "${RUN_MODE}" == "sbatch" ]]; then

    JOB_IDS=()

    for TAU_CASE in "${TAU_CASES[@]}"; do
        for N in "${RESOLUTIONS[@]}"; do
            CASE_DIR="${WORK_DIR}/horiz_solid_${TAU_CASE}_${N}"
            LABEL="hs_${TAU_CASE}_${N}"

            if [ "$N" -ge "$PARALLEL_THRESHOLD" ]; then
                NPROCS=$(grep 'numberOfSubdomains' "${CASE_DIR}/system/decomposeParDict" \
                    | awk '{print $2}' | tr -d ';')
                RUN_CMD="./Allrun -parallel"
            else
                NPROCS=1
                RUN_CMD="./Allrun"
            fi

            cat > "${CASE_DIR}/slurm_run.sh" << EOFSLURM
#!/bin/bash
#SBATCH --job-name=${LABEL}
#SBATCH --partition=${PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=${NPROCS}
#SBATCH --time=${WALLTIME}
#SBATCH --output=slurm_%j.out
#SBATCH --error=slurm_%j.err

module purge
module load ${OPENFOAM_MODULE}

cd "${CASE_DIR}"

echo "Starting ${LABEL} (N=${N}, nprocs=${NPROCS})"
date

${RUN_CMD}

echo "Simulation complete: ${LABEL}"
date
EOFSLURM

            JOB_ID=$(sbatch "${CASE_DIR}/slurm_run.sh" | awk '{print $4}')
            JOB_IDS+=("$JOB_ID")
            echo "  Submitted ${LABEL}: Job ID ${JOB_ID} (nprocs=${NPROCS})"
        done
    done

    # Submit post-processing job depending on all simulations
    ALL_JOB_IDS=$(IFS=:; echo "${JOB_IDS[*]}")

    cat > "${WORK_DIR}/slurm_postprocess.sh" << EOFPP
#!/bin/bash
#SBATCH --job-name=hs_postprocess
#SBATCH --partition=${PARTITION}
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=01:00:00
#SBATCH --output=slurm_pp_%j.out
#SBATCH --error=slurm_pp_%j.err

module purge
module load ${OPENFOAM_MODULE}

cd "${WORK_DIR}"

echo "Extracting mass data..."
date

# Extract mass data from logs
CSV_DIR="${WORK_DIR}/mass_convergence_csv"
mkdir -p "\${CSV_DIR}"

for TAU_CASE in ${TAU_CASES[*]}; do
    for N in ${RESOLUTIONS[*]}; do
        CASE_DIR="${WORK_DIR}/horiz_solid_\${TAU_CASE}_\${N}"
        [ -d "\${CASE_DIR}" ] || continue

        LOGFILE=""
        for candidate in "\${CASE_DIR}/log.meltPoolFoam" "\${CASE_DIR}/log.slmMeltPoolFoam"; do
            [ -f "\${candidate}" ] && LOGFILE="\${candidate}" && break
        done
        [ -z "\${LOGFILE}" ] && LOGFILE=\$(find "\${CASE_DIR}" -maxdepth 1 -name "log.*Foam" -type f 2>/dev/null | head -1)
        [ -z "\${LOGFILE}" ] && continue

        MASS_CSV="\${CSV_DIR}/mass_\${TAU_CASE}_\${N}.csv"
        awk '/^Time =/ { time = \$3 }
             /^Mass in metal:/ { print time "," \$4 }' "\${LOGFILE}" > "\${MASS_CSV}.tmp"

        if [ -s "\${MASS_CSV}.tmp" ]; then
            echo "Time,Mass" > "\${MASS_CSV}"
            cat "\${MASS_CSV}.tmp" >> "\${MASS_CSV}"
            rm "\${MASS_CSV}.tmp"

            INITIAL_MASS=\$(awk '/-- Mass in metal =/{print \$6; exit}' "\${LOGFILE}")
            [ -z "\${INITIAL_MASS}" ] && INITIAL_MASS=\$(awk -F',' 'NR==2{print \$2; exit}' "\${MASS_CSV}")
            echo "\${INITIAL_MASS}" > "\${CSV_DIR}/initial_mass_\${TAU_CASE}_\${N}.txt"
            echo "  Extracted mass_\${TAU_CASE}_\${N}.csv"
        else
            rm -f "\${MASS_CSV}.tmp"
            echo "  WARNING: no mass data for \${TAU_CASE}_\${N}"
        fi
    done
done

echo "Running Python analysis..."
module load python
ROOT_DIR="${WORK_DIR}" python3 ${SCRIPT_DIR}/mass_convergence_analysis.py

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

    for TAU_CASE in "${TAU_CASES[@]}"; do
        for N in "${RESOLUTIONS[@]}"; do
            CASE_DIR="${WORK_DIR}/horiz_solid_${TAU_CASE}_${N}"
            LABEL="horiz_solid_${TAU_CASE}_${N}"
            echo "  Running ${LABEL}..."

            cd "${CASE_DIR}"
            if [ "$N" -ge "$PARALLEL_THRESHOLD" ]; then
                ./Allrun -parallel
            else
                ./Allrun
            fi
            cd "${WORK_DIR}"

            echo "  Finished ${LABEL}"
        done
    done

    # ---------- Extract mass data ----------
    echo ""
    echo "Extracting mass data from logs..."

    CSV_DIR="${WORK_DIR}/mass_convergence_csv"
    mkdir -p "${CSV_DIR}"

    for TAU_CASE in "${TAU_CASES[@]}"; do
        for N in "${RESOLUTIONS[@]}"; do
            CASE_DIR="${WORK_DIR}/horiz_solid_${TAU_CASE}_${N}"
            [ -d "${CASE_DIR}" ] || continue

            LOGFILE=""
            for candidate in "${CASE_DIR}/log.meltPoolFoam" "${CASE_DIR}/log.slmMeltPoolFoam"; do
                [ -f "${candidate}" ] && LOGFILE="${candidate}" && break
            done
            [ -z "${LOGFILE}" ] && LOGFILE=$(find "${CASE_DIR}" -maxdepth 1 -name "log.*Foam" -type f 2>/dev/null | head -1)
            [ -z "${LOGFILE}" ] && continue

            MASS_CSV="${CSV_DIR}/mass_${TAU_CASE}_${N}.csv"
            awk '/^Time =/ { time = $3 }
                 /^Mass in metal:/ { print time "," $4 }' "${LOGFILE}" > "${MASS_CSV}.tmp"

            if [ -s "${MASS_CSV}.tmp" ]; then
                echo "Time,Mass" > "${MASS_CSV}"
                cat "${MASS_CSV}.tmp" >> "${MASS_CSV}"
                rm "${MASS_CSV}.tmp"

                INITIAL_MASS=$(awk '/-- Mass in metal =/{print $6; exit}' "${LOGFILE}")
                [ -z "${INITIAL_MASS}" ] && INITIAL_MASS=$(awk -F',' 'NR==2{print $2; exit}' "${MASS_CSV}")
                echo "${INITIAL_MASS}" > "${CSV_DIR}/initial_mass_${TAU_CASE}_${N}.txt"
                echo "  Extracted mass_${TAU_CASE}_${N}.csv"
            else
                rm -f "${MASS_CSV}.tmp"
                echo "  WARNING: no mass data for ${TAU_CASE}_${N}"
            fi
        done
    done

    # ---------- Run Python analysis ----------
    echo ""
    echo "Running Python analysis..."
    ROOT_DIR="${WORK_DIR}" python3 "${SCRIPT_DIR}/mass_convergence_analysis.py"

    echo ""
    echo "All done!"
fi
