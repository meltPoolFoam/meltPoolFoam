
#!/bin/bash
#=============================================================================
# run_horizontal_solidification_convergence.sh
#
# Usage:
#   ./run_horizontal_solidification_convergence.sh [--sbatch | --manual]
#
# Description:
#   Creates horiz_solid_{corr|nocorr}_{N} folders for each mesh resolution
#   and tau correction case, copies base case, modifies blockMeshDict and
#   controlDict, runs simulations, and generates convergence plots of
#   relative mass error vs time.
#=============================================================================

set -e

# ========================== CONFIGURATION ==================================

ROOT_DIR="$(pwd)"

# List of mesh resolutions
RESOLUTIONS=(16 32)

# Run mode: "sbatch" or "manual" (default: manual)
RUN_MODE="manual"

# Parse command-line arguments
if [[ "$1" == "--sbatch" ]]; then
    RUN_MODE="sbatch"
elif [[ "$1" == "--manual" ]]; then
    RUN_MODE="manual"
fi

# Two tau correction cases
# Case 1: tauCorr = deltaT (correction ON)
# Case 2: tauCorr = 1e10   (correction OFF)
TAU_CASES=("corr" "nocorr")
declare -A TAU_VALUES
TAU_VALUES["corr"]="USE_DELTAT"   # Will be set equal to deltaT
TAU_VALUES["nocorr"]="1e10"

# Base deltaT for N=16 cells
BASE_DELTAT="2e-4"
BASE_N=16

# Python script for post-processing
PYTHON_SCRIPT="postprocess_horizontal_solidification.py"

# ========================== FUNCTIONS ======================================

compute_deltaT() {
    local N=$1
    python3 -c "
ratio = (${BASE_N} / ${N}) ** 2
dt = ratio * ${BASE_DELTAT}
print(f'{dt:.6e}')
"
}

# ========================== MAIN ===========================================

echo "============================================================"
echo " Horizontal Solidification 2D Convergence Study"
echo " (tau correction ON vs OFF)"
echo "============================================================"
echo " Root directory : ${ROOT_DIR}"
echo " Resolutions    : ${RESOLUTIONS[*]}"
echo " Tau cases      : ${TAU_CASES[*]}"
echo " Run mode       : ${RUN_MODE}"
echo "============================================================"

# ---------- Step 1: Create folders and modify files ----------

for TAU_CASE in "${TAU_CASES[@]}"; do
    for N in "${RESOLUTIONS[@]}"; do
        CASE_DIR="${ROOT_DIR}/horiz_solid_${TAU_CASE}_${N}"
        echo ""
        echo "----------------------------------------------"
        echo " Setting up case: horiz_solid_${TAU_CASE}_${N}"
        echo "----------------------------------------------"

        # Skip if folder already exists
        if [ -d "${CASE_DIR}" ]; then
            echo "  Folder ${CASE_DIR} already exists, skipping setup."
            continue
        fi

        # Create new folder
        mkdir -p "${CASE_DIR}"

        # Copy base case contents
        echo "  Copying base case files..."
        cp -r "${ROOT_DIR}/0" "${CASE_DIR}/"
        cp -r "${ROOT_DIR}/constant" "${CASE_DIR}/"
        cp -r "${ROOT_DIR}/system" "${CASE_DIR}/"
        if [ -f "${ROOT_DIR}/Allrun" ]; then
            cp "${ROOT_DIR}/Allrun" "${CASE_DIR}/"
            chmod +x "${CASE_DIR}/Allrun"
        fi
        if [ -f "${ROOT_DIR}/Allclean" ]; then
            cp "${ROOT_DIR}/Allclean" "${CASE_DIR}/"
            chmod +x "${CASE_DIR}/Allclean"
        fi

        # ---- Modify blockMeshDict ----
        BLOCKMESHDICT="${CASE_DIR}/system/blockMeshDict"
        echo "  Modifying blockMeshDict: cells = (${N} 1 ${N})"

        # Replace the cell count line: (XX 1 XX) -> (N 1 N)
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' -E "s/^ \([[:space:]]*[0-9]+[[:space:]]+1[[:space:]]+[0-9]+[[:space:]]*\)/(${N} 1 ${N})/g" "${BLOCKMESHDICT}"
        else
            sed -i -E "s/^ \([[:space:]]*[0-9]+[[:space:]]+1[[:space:]]+[0-9]+[[:space:]]*\)/(${N} 1 ${N})/g" "${BLOCKMESHDICT}"
        fi

        # ---- Modify controlDict ----
        CONTROLDICT="${CASE_DIR}/system/controlDict"
        DELTAT=$(compute_deltaT ${N})
        echo "  Modifying controlDict: deltaT = ${DELTAT}"

        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' -E "s/^(deltaT[[:space:]]+)[^;]+;/\1${DELTAT};/" "${CONTROLDICT}"
        else
            sed -i -E "s/^(deltaT[[:space:]]+)[^;]+;/\1${DELTAT};/" "${CONTROLDICT}"
        fi

        # ---- Modify tauCorr in transportProperties or controlDict ----
        # Search for tauCorr in constant/transportProperties or system/controlDict
        TAU_VAL="${TAU_VALUES[${TAU_CASE}]}"

        if [[ "${TAU_VAL}" == "USE_DELTAT" ]]; then
            TAU_VAL="${DELTAT}"
        fi

        echo "  Setting tauCorr = ${TAU_VAL}"

        # Try transportProperties first
        TRANSPORT_PROPS="${CASE_DIR}/constant/transportProperties"
        if [ -f "${TRANSPORT_PROPS}" ] && grep -q "tauCorr" "${TRANSPORT_PROPS}"; then
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' -E "s/^([[:space:]]*tauCorr[[:space:]]+)[^;]+;/\1${TAU_VAL};/" "${TRANSPORT_PROPS}"
            else
                sed -i -E "s/^([[:space:]]*tauCorr[[:space:]]+)[^;]+;/\1${TAU_VAL};/" "${TRANSPORT_PROPS}"
            fi
        fi



        echo "  Setup complete for horiz_solid_${TAU_CASE}_${N}"
    done
done

# ---------- Step 2: Run simulations ----------

echo ""
echo "============================================================"
echo " Running simulations (mode: ${RUN_MODE})"
echo "============================================================"

PIDS=()
CASE_LABELS=()

for TAU_CASE in "${TAU_CASES[@]}"; do
    for N in "${RESOLUTIONS[@]}"; do
        CASE_DIR="${ROOT_DIR}/horiz_solid_${TAU_CASE}_${N}"
        LABEL="horiz_solid_${TAU_CASE}_${N}"
        echo "  Launching ${LABEL}..."

        cd "${CASE_DIR}"

        if [[ "${RUN_MODE}" == "sbatch" ]]; then
            cat > "${CASE_DIR}/job_${LABEL}.sh" << SLURM_EOF
#!/bin/bash
#SBATCH --job-name=${LABEL}
#SBATCH --output=${LABEL}_%j.out
#SBATCH --error=${LABEL}_%j.err
#SBATCH --ntasks=1
#SBATCH --time=48:00:00

cd ${CASE_DIR}
./Allrun
SLURM_EOF
            chmod +x "${CASE_DIR}/job_${LABEL}.sh"
            sbatch "${CASE_DIR}/job_${LABEL}.sh"
        else
            ./Allrun > log.Allrun 2>&1 &
            PIDS+=($!)
            CASE_LABELS+=("${LABEL}")
            echo "    PID: ${PIDS[-1]}"
        fi

        cd "${ROOT_DIR}"
    done
done

# ---------- Step 3: Wait for completion ----------

if [[ "${RUN_MODE}" == "manual" ]]; then
    echo ""
    echo "============================================================"
    echo " Waiting for all simulations to complete..."
    echo "============================================================"

    for i in "${!PIDS[@]}"; do
        LABEL=${CASE_LABELS[$i]}
        PID=${PIDS[$i]}
        echo "  Waiting for ${LABEL} (PID: ${PID})..."
        wait ${PID}
        EXIT_CODE=$?
        if [ ${EXIT_CODE} -eq 0 ]; then
            echo "    ${LABEL} completed successfully."
        else
            echo "    WARNING: ${LABEL} exited with code ${EXIT_CODE}!"
        fi
    done

    echo ""
    echo " All simulations finished."
elif [[ "${RUN_MODE}" == "sbatch" ]]; then
    echo ""
    echo "============================================================"
    echo " All jobs submitted to SLURM."
    echo " Monitor with: squeue -u \$USER"
    echo "============================================================"
    read -p " Wait for all SLURM jobs to finish? (y/n): " WAIT_ANSWER
    if [[ "${WAIT_ANSWER}" == "y" || "${WAIT_ANSWER}" == "Y" ]]; then
        echo " Waiting for SLURM jobs to complete..."
        while true; do
            RUNNING=$(squeue -u "$USER" --name="horiz_solid_*" -h 2>/dev/null | wc -l)
            if [ "${RUNNING}" -eq 0 ]; then
                echo " All SLURM jobs completed."
                break
            fi
            echo "   ${RUNNING} jobs still running... checking again in 60s"
            sleep 60
        done
    else
        echo " Exiting. Run post-processing manually after jobs complete."
        exit 0
    fi
fi

# ---------- Step 3.5: Extract mass data from logs ----------

echo ""
echo "============================================================"
echo " Extracting mass data from simulation logs"
echo "============================================================"

CSV_DIR="${ROOT_DIR}/mass_convergence_csv"
mkdir -p "${CSV_DIR}"

for TAU_CASE in "${TAU_CASES[@]}"; do
    for N in "${RESOLUTIONS[@]}"; do
        CASE_DIR="${ROOT_DIR}/horiz_solid_${TAU_CASE}_${N}"
        LABEL="horiz_solid_${TAU_CASE}_${N}"

        if [ ! -d "${CASE_DIR}" ]; then
            echo "  WARNING: ${CASE_DIR} not found, skipping"
            continue
        fi

        echo "  Processing ${LABEL}..."

        # Find the solver log file
        LOGFILE=""
        for candidate in \
            "${CASE_DIR}/log.meltPoolFoam" \
            "${CASE_DIR}/log.slmMeltPoolFoam" \
            "${CASE_DIR}/log.Allrun"; do
            if [ -f "${candidate}" ]; then
                LOGFILE="${candidate}"
                break
            fi
        done

        # If not found, search for any log file
        if [ -z "${LOGFILE}" ]; then
            LOGFILE=$(find "${CASE_DIR}" -maxdepth 1 -name "log.*Foam" -type f 2>/dev/null | head -1)
        fi

        if [ -z "${LOGFILE}" ] || [ ! -f "${LOGFILE}" ]; then
            echo "    WARNING: No log file found in ${CASE_DIR}"
            continue
        fi

        echo "    Using log: ${LOGFILE}"

        # Extract time and mass data
        MASS_CSV="${CSV_DIR}/mass_${TAU_CASE}_${N}.csv"
        awk '/^Time =/ { time = $3 }
             /^Mass in metal:/ { print time "," $4 }' "${LOGFILE}" > "${MASS_CSV}.tmp"

        if [ -s "${MASS_CSV}.tmp" ]; then
            echo "Time,Mass" > "${MASS_CSV}"
            cat "${MASS_CSV}.tmp" >> "${MASS_CSV}"
            rm "${MASS_CSV}.tmp"

            # Extract initial mass
            INITIAL_MASS=$(awk '/-- Mass in metal =/{print $6; exit}' "${LOGFILE}")
            if [ -z "${INITIAL_MASS}" ]; then
                # Fallback: use first mass value
                INITIAL_MASS=$(awk -F',' 'NR==2{print $2; exit}' "${MASS_CSV}")
            fi
            echo "${INITIAL_MASS}" > "${CSV_DIR}/initial_mass_${TAU_CASE}_${N}.txt"

            echo "    Saved ${MASS_CSV} (initial mass: ${INITIAL_MASS})"
        else
            rm -f "${MASS_CSV}.tmp"
            echo "    WARNING: No mass data extracted from ${LOGFILE}"
        fi
    done
done

echo ""
echo " Mass data extraction complete."

# ---------- Step 4: Post-processing with Python ----------

echo ""
echo "============================================================"
echo " Running post-processing (Python)"
echo "============================================================"

# Check Python dependencies
echo "  Checking Python dependencies..."
for pkg in pandas numpy matplotlib; do
    python3 -c "import ${pkg}" 2>/dev/null || {
        echo "  Installing ${pkg}..."
        python3 -m pip install "${pkg}"
    }
done

# Generate the Python post-processing script
cat > "${ROOT_DIR}/${PYTHON_SCRIPT}" << 'PYEOF'
#!/usr/bin/env python3
"""
Post-processing script for horizontal solidification 2D convergence study.
Plots relative mass error vs time for two tau correction cases
(correction ON vs OFF) across multiple mesh resolutions.
"""

import os
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors

# ============================================================
# Plot settings (matching the 1D Stefan study style)
# ============================================================
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['Times New Roman'] + plt.rcParams['font.serif']
plt.rcParams["mathtext.fontset"] = "cm"
plt.rcParams['font.size'] = 12
plt.rcParams['axes.titlesize'] = 18
plt.rcParams['axes.labelsize'] = 14
plt.rcParams['xtick.labelsize'] = 16
plt.rcParams['ytick.labelsize'] = 16
plt.rcParams['legend.fontsize'] = 12
plt.rcParams['figure.titlesize'] = 20

# ============================================================
# Configuration
# ============================================================
RESOLUTIONS = [16, 32, 64, 128, 256]
ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
CSV_DIR = os.path.join(ROOT_DIR, 'mass_convergence_csv')

TAU_CASES = {
    'corr':   r'$\tau_{\mathrm{corr}} = \Delta t$ (correction ON)',
    'nocorr': r'$\tau_{\mathrm{corr}} = 10^{10}$ (correction OFF)',
}

# Color maps for different resolutions
COLORS = list(mcolors.TABLEAU_COLORS.values())
LINESTYLES = ['-', '--', '-.', ':', (0, (3, 1, 1, 1))]

# ============================================================
# Figure: Relative mass error vs time (one subplot per tau case)
# ============================================================
print("Generating relative mass error convergence plots...")

fig, axes = plt.subplots(1, 2, figsize=(12, 5), sharey=True)

for ax_idx, (tau_key, tau_label) in enumerate(TAU_CASES.items()):
    ax = axes[ax_idx]

    for res_idx, N in enumerate(RESOLUTIONS):
        mass_csv = os.path.join(CSV_DIR, f'mass_{tau_key}_{N}.csv')
        init_mass_file = os.path.join(CSV_DIR, f'initial_mass_{tau_key}_{N}.txt')

        if not os.path.isfile(mass_csv):
            print(f"  WARNING: {mass_csv} not found, skipping N={N}")
            continue

        # Read mass data
        df = pd.read_csv(mass_csv)
        if df.empty:
            print(f"  WARNING: {mass_csv} is empty, skipping N={N}")
            continue

        # Read initial mass
        if os.path.isfile(init_mass_file):
            with open(init_mass_file, 'r') as f:
                initial_mass = float(f.read().strip())
        else:
            initial_mass = df['Mass'].iloc[0]

        # Compute relative mass error (%)
        relative_error = (df['Mass'] - initial_mass) / initial_mass * 100.0

        color = COLORS[res_idx % len(COLORS)]
        ls = LINESTYLES[res_idx % len(LINESTYLES)]

        ax.plot(df['Time'], relative_error,
                label=f'N = {N}',
                color=color,
                linestyle=ls,
                linewidth=2)

    ax.set_xlabel('Time [s]')
    if ax_idx == 0:
        ax.set_ylabel('Relative Change in Mass [%]')
    ax.set_yscale('log')
    ax.set_title(tau_label)
    ax.legend(loc='best', fontsize=10)
    ax.grid(True, linestyle='-.', alpha=0.7)

plt.tight_layout()
out_path = os.path.join(ROOT_DIR, 'relative_mass_error_vs_time.pdf')
plt.savefig(out_path, dpi=150)
print(f"  Saved {out_path}")
plt.close()

# ============================================================
# Figure: Absolute relative mass error vs time (log scale y)
# ============================================================
print("Generating absolute relative mass error plots...")

fig, axes = plt.subplots(1, 2, figsize=(12, 5), sharey=True)

for ax_idx, (tau_key, tau_label) in enumerate(TAU_CASES.items()):
    ax = axes[ax_idx]

    for res_idx, N in enumerate(RESOLUTIONS):
        mass_csv = os.path.join(CSV_DIR, f'mass_{tau_key}_{N}.csv')
        init_mass_file = os.path.join(CSV_DIR, f'initial_mass_{tau_key}_{N}.txt')

        if not os.path.isfile(mass_csv):
            continue

        df = pd.read_csv(mass_csv)
        if df.empty:
            continue

        if os.path.isfile(init_mass_file):
            with open(init_mass_file, 'r') as f:
                initial_mass = float(f.read().strip())
        else:
            initial_mass = df['Mass'].iloc[0]

        # Absolute relative mass error (%)
        abs_relative_error = np.abs((df['Mass'] - initial_mass) / initial_mass * 100.0)
        # Replace zeros with tiny value for log scale
        abs_relative_error = abs_relative_error.replace(0, np.nan)

        color = COLORS[res_idx % len(COLORS)]
        ls = LINESTYLES[res_idx % len(LINESTYLES)]

        ax.plot(df['Time'], abs_relative_error,
                label=f'N = {N}',
                color=color,
                linestyle=ls,
                linewidth=2)

    ax.set_xlabel('Time [s]')
    if ax_idx == 0:
        ax.set_ylabel('|Relative Change in Mass| [%]')
    ax.set_yscale('log')
    ax.set_title(tau_label)
    ax.legend(loc='best', fontsize=10)
    ax.grid(True, linestyle='-.', alpha=0.7)

plt.tight_layout()
out_path = os.path.join(ROOT_DIR, 'abs_relative_mass_error_vs_time.pdf')
plt.savefig(out_path, dpi=150)
print(f"  Saved {out_path}")
plt.close()

# ============================================================
# Figure: Final mass error vs mesh resolution (convergence)
# ============================================================
print("Generating final mass error vs mesh resolution plot...")

fig, ax = plt.subplots(1, 1, figsize=(6, 5))

for tau_key, tau_label in TAU_CASES.items():
    final_errors = []
    valid_resolutions = []

    for N in RESOLUTIONS:
        mass_csv = os.path.join(CSV_DIR, f'mass_{tau_key}_{N}.csv')
        init_mass_file = os.path.join(CSV_DIR, f'initial_mass_{tau_key}_{N}.txt')

        if not os.path.isfile(mass_csv):
            continue

        df = pd.read_csv(mass_csv)
        if df.empty:
            continue

        if os.path.isfile(init_mass_file):
            with open(init_mass_file, 'r') as f:
                initial_mass = float(f.read().strip())
        else:
            initial_mass = df['Mass'].iloc[0]

        # Final absolute relative mass error
        final_mass = df['Mass'].iloc[-1]
        final_err = abs((final_mass - initial_mass) / initial_mass * 100.0)
        final_errors.append(final_err)
        valid_resolutions.append(N)

    if valid_resolutions:
        marker = 'o' if tau_key == 'corr' else 's'
        ax.plot(valid_resolutions, final_errors,
                marker=marker, markersize=8, linewidth=2,
                label=tau_label)

# Add reference convergence lines
if valid_resolutions:
    N_arr = np.array(valid_resolutions, dtype=float)
    # First order reference
    C1 = final_errors[0] * valid_resolutions[0] if final_errors else 1.0
    first_order = C1 / N_arr
    ax.plot(N_arr, first_order, 'k--', linewidth=1.5, alpha=0.5,
            label=r'$\mathcal{O}(h^1)$')
    # Second order reference
    C2 = final_errors[0] * valid_resolutions[0]**2 if final_errors else 1.0
    second_order = C2 / N_arr**2
    ax.plot(N_arr, second_order, 'k:', linewidth=1.5, alpha=0.5,
            label=r'$\mathcal{O}(h^2)$')

ax.set_xlabel('Grid size $N$')
ax.set_ylabel('|Relative Mass Error| at final time [%]')
ax.set_xscale('log')
ax.set_yscale('log')
ax.legend(loc='best')
ax.grid(True, linestyle='-.', alpha=0.7)
ax.set_xticks(RESOLUTIONS)
ax.set_xticklabels([str(n) for n in RESOLUTIONS])

plt.tight_layout()
out_path = os.path.join(ROOT_DIR, 'mass_error_convergence.pdf')
plt.savefig(out_path, dpi=150)
print(f"  Saved {out_path}")
plt.close()

# ============================================================
# Figure: Max mass error vs mesh resolution
# ============================================================
print("Generating max mass error vs mesh resolution plot...")

fig, ax = plt.subplots(1, 1, figsize=(6, 5))

for tau_key, tau_label in TAU_CASES.items():
    max_errors = []
    valid_resolutions = []

    for N in RESOLUTIONS:
        mass_csv = os.path.join(CSV_DIR, f'mass_{tau_key}_{N}.csv')
        init_mass_file = os.path.join(CSV_DIR, f'initial_mass_{tau_key}_{N}.txt')

        if not os.path.isfile(mass_csv):
            continue

        df = pd.read_csv(mass_csv)
        if df.empty:
            continue

        if os.path.isfile(init_mass_file):
            with open(init_mass_file, 'r') as f:
                initial_mass = float(f.read().strip())
        else:
            initial_mass = df['Mass'].iloc[0]

        max_err = np.max(np.abs((df['Mass'] - initial_mass) / initial_mass * 100.0))
        max_errors.append(max_err)
        valid_resolutions.append(N)

    if valid_resolutions:
        marker = 'o' if tau_key == 'corr' else 's'
        ax.plot(valid_resolutions, max_errors,
                marker=marker, markersize=8, linewidth=2,
                label=tau_label)

# Reference lines
if valid_resolutions and max_errors:
    N_arr = np.array(valid_resolutions, dtype=float)
    C1 = max_errors[0] * valid_resolutions[0]
    ax.plot(N_arr, C1 / N_arr, 'k--', linewidth=1.5, alpha=0.5,
            label=r'$\mathcal{O}(h^1)$')
    C2 = max_errors[0] * valid_resolutions[0]**2
    ax.plot(N_arr, C2 / N_arr**2, 'k:', linewidth=1.5, alpha=0.5,
            label=r'$\mathcal{O}(h^2)$')

ax.set_xlabel('Grid size $N$')
ax.set_ylabel('Max |Relative Mass Error| [%]')
ax.set_xscale('log')
ax.set_yscale('log')
ax.legend(loc='best')
ax.grid(True, linestyle='-.', alpha=0.7)
ax.set_xticks(RESOLUTIONS)
ax.set_xticklabels([str(n) for n in RESOLUTIONS])

plt.tight_layout()
out_path = os.path.join(ROOT_DIR, 'max_mass_error_convergence.pdf')
plt.savefig(out_path, dpi=150)
print(f"  Saved {out_path}")
plt.close()

print("\n============================================")
print(" Post-processing complete!")
print("============================================")
PYEOF

# Run the Python post-processing script
python3 "${ROOT_DIR}/${PYTHON_SCRIPT}"

echo ""
echo "============================================================"
echo " All done!"
echo "============================================================"
