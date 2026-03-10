#!/bin/bash
#=============================================================================
# run_stefan_convergence.sh
#
# Usage:
#   ./run_stefan_convergence.sh [--sbatch | --manual]
#
# Description:
#   Creates 1D_stefan{N} folders for each mesh resolution, copies base case,
#   modifies blockMeshDict and controlDict, runs simulations, and generates
#   convergence plots.
#=============================================================================

set -e

# ========================== CONFIGURATION ==================================

# Root folder containing the base case (0, Allclean, Allrun, constant, system)
ROOT_DIR="$(pwd)"

# List of mesh resolutions
RESOLUTIONS=(16 32 64 128 256 512 1024)

# Run mode: "sbatch" or "manual" (default: manual)
RUN_MODE="manual"

# Parse command-line arguments
if [[ "$1" == "--sbatch" ]]; then
    RUN_MODE="sbatch"
elif [[ "$1" == "--manual" ]]; then
    RUN_MODE="manual"
fi

# Sigmoid function type (only 'cut')
SIGMOID="cut"

# Density case label (used for CSV output folder naming)
DENSITY_CASE="den_change_low"

# Start time for the simulation (used in post-processing)
START_TIME=100

# Read time for temperature distribution extraction
READ_TIME=300

# Base deltaT for N=16 cells
BASE_DELTAT="0.05"
BASE_N=16

# Python script for post-processing
PYTHON_SCRIPT="postprocess_cut.py"

# ========================== FUNCTIONS ======================================

compute_deltaT() {
    # deltaT scales as (BASE_N / N)^2 * BASE_DELTAT
    # For N=16:  deltaT = 0.125e-2 = 1.25e-3
    # For N=32:  deltaT = 0.03125e-2 = 3.125e-4
    # For N=64:  deltaT = 0.0078125e-2 = 7.8125e-5
    # etc.
    local N=$1
    python3 -c "print(f'{${BASE_DELTAT}:.6e}')" 2>/dev/null || \
    python3 -c "
ratio = (${BASE_N} / ${N}) ** 2
dt = 1. * ${BASE_DELTAT}
print(f'{dt:.6e}')
"
}

# ========================== MAIN ===========================================

echo "============================================="
echo " Stefan 1D Convergence Study (cut function)"
echo "============================================="
echo " Root directory : ${ROOT_DIR}"
echo " Resolutions    : ${RESOLUTIONS[*]}"
echo " Run mode       : ${RUN_MODE}"
echo " Sigmoid        : ${SIGMOID}"
echo "============================================="

# ---------- Step 1: Create folders and modify files ----------

for N in "${RESOLUTIONS[@]}"; do
    CASE_DIR="${ROOT_DIR}/1D_stefan${N}"
    echo ""
    echo "----------------------------------------------"
    echo " Setting up case: 1D_stefan${N}"
    echo "----------------------------------------------"

    # Remove old folder if it exists
    if [ -d "${CASE_DIR}" ]; then
        #echo "  Removing existing ${CASE_DIR}"
        #rm -rf "${CASE_DIR}"
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
    cp "${ROOT_DIR}/Allrun" "${CASE_DIR}/"
    cp "${ROOT_DIR}/Allclean" "${CASE_DIR}/"

    # Make Allrun and Allclean executable
    chmod +x "${CASE_DIR}/Allrun" "${CASE_DIR}/Allclean"

    # ---- Modify blockMeshDict ----
    BLOCKMESHDICT="${CASE_DIR}/system/blockMeshDict"
    echo "  Modifying blockMeshDict: cells = (${N} 1 1)"

    # Replace the cell count line: (XX 1 1) -> (N 1 1)
    # This handles various formats of the hex block definition
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS sed
        sed -i '' -E "s/^ \([[:space:]]*[0-9]+[[:space:]]+1[[:space:]]+1[[:space:]]*\)/ (${N} 1 1)/g" "${BLOCKMESHDICT}"
    else
        # GNU sed
        sed -i -E "s/^ \([[:space:]]*[0-9]+[[:space:]]+1[[:space:]]+1[[:space:]]*\)/ (${N} 1 1)/g" "${BLOCKMESHDICT}"
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

    echo "  Setup complete for 1D_stefan${N}"
done

# ---------- Step 2: Run simulations ----------

echo ""
echo "============================================="
echo " Running simulations (mode: ${RUN_MODE})"
echo "============================================="

PIDS=()

for N in "${RESOLUTIONS[@]}"; do
    CASE_DIR="${ROOT_DIR}/1D_stefan${N}"
    echo "  Launching 1D_stefan${N}..."

    cd "${CASE_DIR}"

    if [[ "${RUN_MODE}" == "sbatch" ]]; then
        # Create a SLURM job script
        cat > "${CASE_DIR}/job_stefan_${N}.sh" << SLURM_EOF
#!/bin/bash
#SBATCH --job-name=stefan_${N}
#SBATCH --output=stefan_${N}_%j.out
#SBATCH --error=stefan_${N}_%j.err
#SBATCH --ntasks=1
#SBATCH --time=24:00:00

cd ${CASE_DIR}
./Allrun
SLURM_EOF
        chmod +x "${CASE_DIR}/job_stefan_${N}.sh"
        sbatch "${CASE_DIR}/job_stefan_${N}.sh"
    else
        # Run manually in background
        ./Allrun > log.Allrun 2>&1 &
        PIDS+=($!)
        echo "    PID: ${PIDS[-1]}"
    fi

    cd "${ROOT_DIR}"
done

# ---------- Step 3: Wait for completion ----------

if [[ "${RUN_MODE}" == "manual" ]]; then
    echo ""
    echo "============================================="
    echo " Waiting for all simulations to complete..."
    echo "============================================="

    for i in "${!PIDS[@]}"; do
        N=${RESOLUTIONS[$i]}
        PID=${PIDS[$i]}
        echo "  Waiting for 1D_stefan${N} (PID: ${PID})..."
        wait ${PID}
        EXIT_CODE=$?
        if [ ${EXIT_CODE} -eq 0 ]; then
            echo "    1D_stefan${N} completed successfully."
        else
            echo "    WARNING: 1D_stefan${N} exited with code ${EXIT_CODE}!"
        fi
    done

    echo ""
    echo " All simulations finished."
elif [[ "${RUN_MODE}" == "sbatch" ]]; then
    echo ""
    echo "============================================="
    echo " All jobs submitted to SLURM."
    echo " Monitor with: squeue -u \$USER"
    echo " Once all jobs complete, run the post-processing"
    echo " script manually:"
    echo "   python3 ${PYTHON_SCRIPT}"
    echo "============================================="
    # For sbatch mode, we can optionally wait or just exit
    echo ""
    read -p " Wait for all SLURM jobs to finish? (y/n): " WAIT_ANSWER
    if [[ "${WAIT_ANSWER}" == "y" || "${WAIT_ANSWER}" == "Y" ]]; then
        echo " Waiting for SLURM jobs to complete..."
        # Poll squeue for our jobs
        while true; do
            RUNNING=$(squeue -u "$USER" --name="stefan_*" -h 2>/dev/null | wc -l)
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

# ---------- Step 3.5: Transform dat files to CSV and collect results ----------

echo ""
echo "============================================="
echo " Transforming simulation output to CSV"
echo "============================================="

# Create output CSV directory
CSV_DIR="${ROOT_DIR}/${DENSITY_CASE}_csv"
mkdir -p "${CSV_DIR}"

for N in "${RESOLUTIONS[@]}"; do
    CASE_DIR="${ROOT_DIR}/1D_stefan${N}"

    if [ ! -d "${CASE_DIR}" ]; then
        echo "  WARNING: ${CASE_DIR} not found, skipping N=${N}"
        continue
    fi

    echo "  Processing 1D_stefan${N}..."

    # --- Transform and collect LiqFracInt ---
    LIQ_DAT="${CASE_DIR}/postProcessing/volIntegrate/0/volFieldValue.dat"
    if [ -f "${LIQ_DAT}" ]; then
        OUT_CSV="${CSV_DIR}/LiqFracInt_${SIGMOID}_${N}.csv"
        echo "Time,Value" > "${OUT_CSV}"
        while read -r line; do
            if [[ $line =~ ^# || -z $line ]]; then
                continue
            fi
            time=$(echo $line | awk '{print $1}')
            value=$(echo $line | awk '{print $2}')
            echo "$time,$value" >> "${OUT_CSV}"
        done < "${LIQ_DAT}"
        echo "    Saved ${OUT_CSV}"
    else
        echo "    WARNING: ${LIQ_DAT} not found"
    fi

    # --- Transform and collect U ---
    U_DAT="${CASE_DIR}/postProcessing/boundaryU/0/U"
    # Try alternative paths if not found
    if [ ! -f "${U_DAT}" ]; then
        U_DAT="${CASE_DIR}/postProcessing/boundaryVelocity/0/U"
    fi
    if [ ! -f "${U_DAT}" ]; then
        # Search for any file named U in postProcessing
        U_DAT=$(find "${CASE_DIR}/postProcessing" -name "U" -type f 2>/dev/null | head -1)
    fi

    if [ -f "${U_DAT}" ]; then
        OUT_CSV="${CSV_DIR}/U_${SIGMOID}_${N}.csv"
        echo "Time,U_x" > "${OUT_CSV}"
        while read -r line; do
            if [[ $line =~ ^# || -z $line ]]; then
                continue
            fi
            time=$(echo $line | awk '{print $1}')
            ux=$(echo $line | awk -F'[()]' '{print $2}' | awk '{print $1}')
            echo "$time,$ux" >> "${OUT_CSV}"
        done < "${U_DAT}"
        echo "    Saved ${OUT_CSV}"
    else
        echo "    WARNING: No U file found in postProcessing for N=${N}"
    fi

    # --- Transform and collect Temperature distributions ---
    # Look for sample line data at READ_TIME
    SAMPLE_DIR="${CASE_DIR}/postProcessing/sampleLine/${READ_TIME}"
    # Try alternative paths
    if [ ! -d "${SAMPLE_DIR}" ]; then
        SAMPLE_DIR="${CASE_DIR}/postProcessing/sample/${READ_TIME}"
    fi
    if [ ! -d "${SAMPLE_DIR}" ]; then
        # Search for any directory matching the read time
        SAMPLE_DIR=$(find "${CASE_DIR}/postProcessing" -type d -name "${READ_TIME}" 2>/dev/null | head -1)
    fi

    if [ -d "${SAMPLE_DIR}" ]; then
        OUT_DIR="${CSV_DIR}/TemDitr_${SIGMOID}_${N}/${READ_TIME}"
        mkdir -p "${OUT_DIR}"

        # Find temperature data file (.xy or .csv or .dat)
        TEMP_FILE=$(find "${SAMPLE_DIR}" -type f \( -name "*T*" -o -name "*.xy" -o -name "*.csv" \) 2>/dev/null | head -1)

        if [ -f "${TEMP_FILE}" ]; then
            OUT_CSV="${OUT_DIR}/s1_T.csv"
            # Check if it's already CSV
            if [[ "${TEMP_FILE}" == *.csv ]]; then
                cp "${TEMP_FILE}" "${OUT_CSV}"
            else
                # Convert space/tab separated to CSV (assume columns: x T)
                echo "x,T" > "${OUT_CSV}"
                while read -r line; do
                    if [[ $line =~ ^# || -z $line ]]; then
                        continue
                    fi
                    x_val=$(echo $line | awk '{print $1}')
                    t_val=$(echo $line | awk '{print $2}')
                    echo "$x_val,$t_val" >> "${OUT_CSV}"
                done < "${TEMP_FILE}"
            fi
            echo "    Saved ${OUT_CSV}"
        else
            echo "    WARNING: No temperature file found in ${SAMPLE_DIR}"
        fi
    else
        echo "    WARNING: No sample directory found for time=${READ_TIME}, N=${N}"
    fi

    # --- Also collect temperature at other time steps if they exist ---
    if [ -d "${CASE_DIR}/postProcessing" ]; then
        for SAMPLE_TIME_DIR in $(find "${CASE_DIR}/postProcessing" -mindepth 2 -maxdepth 2 -type d -regex '.*/[0-9]+' 2>/dev/null); do
            TIME_VAL=$(basename "${SAMPLE_TIME_DIR}")
            # Skip if already processed
            if [ "${TIME_VAL}" == "${READ_TIME}" ]; then
                continue
            fi

            TEMP_FILE=$(find "${SAMPLE_TIME_DIR}" -type f \( -name "*T*" -o -name "*.xy" \) 2>/dev/null | head -1)
            if [ -f "${TEMP_FILE}" ]; then
                OUT_DIR="${CSV_DIR}/TemDitr_${SIGMOID}_${N}/${TIME_VAL}"
                mkdir -p "${OUT_DIR}"
                OUT_CSV="${OUT_DIR}/s1_T.csv"
                echo "x,T" > "${OUT_CSV}"
                while read -r line; do
                    if [[ $line =~ ^# || -z $line ]]; then
                        continue
                    fi
                    x_val=$(echo $line | awk '{print $1}')
                    t_val=$(echo $line | awk '{print $2}')
                    echo "$x_val,$t_val" >> "${OUT_CSV}"
                done < "${TEMP_FILE}"
            fi
        done
    fi

done

echo ""
echo " CSV transformation complete."

# ---------- Step 4: Post-processing with Python ----------

echo ""
echo "============================================="
echo " Running post-processing (Python)"
echo "============================================="

# Ensure pip is available, then install required packages
echo "  Checking Python dependencies..."
python3 -m pip --version 2>/dev/null || {
    echo "  pip not found, installing..."
    sudo apt-get update && sudo apt-get install -y python3-pip
}

for pkg in pandas numpy matplotlib scipy; do
    python3 -c "import ${pkg}" 2>/dev/null || {
        echo "  Installing ${pkg}..."
        python3 -m pip install "${pkg}"
    }
done


# Generate the Python post-processing script for 'cut' only
cat > "${ROOT_DIR}/${PYTHON_SCRIPT}" << 'PYEOF'
#!/usr/bin/env python3
"""
Post-processing script for Stefan 1D convergence study.
Only for 'cut' sigmoid function.
"""

import string
import os
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from scipy.special import erf, erfc
from scipy.optimize import root_scalar

# ============================================================
# Plot settings
# ============================================================
plt.rcParams['font.family'] = 'serif'
plt.rcParams['font.serif'] = ['Times New Roman'] + plt.rcParams['font.serif']
plt.rcParams["mathtext.fontset"] = "cm"
plt.rcParams['font.size'] = 12
plt.rcParams['axes.titlesize'] = 18
plt.rcParams['axes.labelsize'] = 14
plt.rcParams['xtick.labelsize'] = 16
plt.rcParams['ytick.labelsize'] = 16
plt.rcParams['legend.fontsize'] = 14
plt.rcParams['figure.titlesize'] = 20

# ============================================================
# Physical parameters
# ============================================================
rho_S = 2700.
rho_L = 2700.
Cp_S = 910.
Cp_L = 1042.4
k_S = 211.
k_L = 91.
T_m = 936.6
H_fus = 383840.

l_x = 1.
T_0_t = 468.3
T_x_0 = 1873.2

# ============================================================
# Analytical solution functions
# ============================================================
def eq_for_lamda_t(lambda_t):
    alpha_S = k_S / (rho_S * Cp_S)
    alpha_L = k_L / (rho_L * Cp_L)
    R_p = rho_S / rho_L
    lhs = lambda_t * np.sqrt(alpha_L) * rho_S * H_fus
    rhs_1 = (k_S * (T_m - T_0_t) * np.exp(-lambda_t**2 * alpha_L / alpha_S)
             / (np.sqrt(np.pi * alpha_S) * erf(lambda_t * np.sqrt(alpha_L / alpha_S))))
    rhs_2 = (k_L * (T_m - T_x_0) * np.exp(-lambda_t**2 * R_p**2)
             / (np.sqrt(np.pi * alpha_L) * erfc(lambda_t * R_p)))
    return lhs - rhs_1 - rhs_2

def X_t_analytic(time):
    alpha_L = k_L / (rho_L * Cp_L)
    lambda_t = root_scalar(eq_for_lamda_t, x0=0.3, x1=2., xtol=1e-8).root
    return 2 * np.sqrt(alpha_L * time) * lambda_t

def X_dot_t_analytic(time):
    alpha_L = k_L / (rho_L * Cp_L)
    lambda_t = root_scalar(eq_for_lamda_t, x0=0.3, x1=2., xtol=1e-8).root
    return lambda_t * np.sqrt(alpha_L / time)

def T_S_t_analytic(x, time, lambda_t):
    alpha_S = k_S / (rho_S * Cp_S)
    alpha_L = k_L / (rho_L * Cp_L)
    return T_0_t + (T_m - T_0_t) * erf(x / (2 * np.sqrt(alpha_S * time))) / erf(lambda_t * np.sqrt(alpha_L / alpha_S))

def T_L_t_analytic(x, time, lambda_t):
    alpha_L = k_L / (rho_L * Cp_L)
    erfc_arg_num = x / (2 * np.sqrt(alpha_L * time)) - lambda_t * (1 - rho_S / rho_L)
    erfc_arg_den = lambda_t * rho_S / rho_L
    return T_x_0 + (T_m - T_x_0) * erfc(erfc_arg_num) / erfc(erfc_arg_den)

def analytical_temperature_in_domain(x_coordinate, time=0):
    front_position = X_t_analytic(time)
    temperature = np.zeros_like(x_coordinate)
    lambda_t = root_scalar(eq_for_lamda_t, x0=0.3, x1=2, xtol=1e-8).root
    solid_region = x_coordinate[x_coordinate < front_position]
    liquid_region = x_coordinate[x_coordinate >= front_position]
    temperature[x_coordinate < front_position] = T_S_t_analytic(solid_region, time, lambda_t)
    temperature[x_coordinate >= front_position] = T_L_t_analytic(liquid_region, time, lambda_t)
    return temperature

# ============================================================
# Configuration
# ============================================================
RESOLUTIONS = [16, 32, 64, 128, 256, 512, 1024]
ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
SIGMOID = 'cut'
DENSITY_CASE = 'den_change_low'
START_TIME = 100
READ_TIME = 300

density_map = {'no_den_change': 2700, 'den_change_low': 2400}

num_config = {'linestyle': '-', 'linewidth': 2, 'markevery': 20, 'zorder': 2, 'color': 'blue'}
num_scat_config = {'s': 40, 'marker': 'x', 'zorder': 3, 'color': 'black'}
axhline_config = {'linestyle': '--', 'linewidth': 1.3, 'color': 'gray', 'zorder': -1}
anal_config = {'linestyle': '-.', 'linewidth': 2}

# ============================================================
# Collect CSV data from simulation folders
# ============================================================
# Create output CSV directory
csv_dir = os.path.join(ROOT_DIR, f'{DENSITY_CASE}_csv')
os.makedirs(csv_dir, exist_ok=True)

print("Collecting simulation results...")

for N in RESOLUTIONS:
    case_dir = os.path.join(ROOT_DIR, f'1D_stefan{N}')
    if not os.path.isdir(case_dir):
        print(f"  WARNING: {case_dir} not found, skipping N={N}")
        continue

    # --- Collect LiqFracInt CSV ---
    liq_frac_src = os.path.join(case_dir, 'postProcessing', 'volIntegrate', '0', 'volFieldValue.dat')
    if os.path.isfile(liq_frac_src):
        # Parse OpenFOAM function object output
        times = []
        values = []
        with open(liq_frac_src, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('#') or not line:
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    times.append(float(parts[0]))
                    values.append(float(parts[1]))
        df = pd.DataFrame({'Time': times, 'Value': values})
        out_path = os.path.join(csv_dir, f'LiqFracInt_{SIGMOID}_{N}.csv')
        df.to_csv(out_path, index=False)
        print(f"  Saved {out_path}")

    # --- Collect Temperature distribution CSV ---
    temp_dir = os.path.join(case_dir, 'postProcessing', 'sampleLine', str(READ_TIME))
    if os.path.isdir(temp_dir):
        temp_csv_dir = os.path.join(csv_dir, f'TemDitr_{SIGMOID}_{N}', str(READ_TIME))
        os.makedirs(temp_csv_dir, exist_ok=True)
        # Look for the temperature sample file
        for fname in os.listdir(temp_dir):
            if fname.endswith('.csv') or fname.endswith('.xy'):
                src = os.path.join(temp_dir, fname)
                dst = os.path.join(temp_csv_dir, 's1_T.csv')
                # If it's .xy format, convert to CSV
                if fname.endswith('.xy'):
                    data = np.loadtxt(src)
                    df = pd.DataFrame({'x': data[:, 0], 'T': data[:, 1]})
                    df.to_csv(dst, index=False)
                else:
                    import shutil
                    shutil.copy2(src, dst)
                print(f"  Saved {dst}")
                break

    # --- Collect velocity CSV ---
    u_src = os.path.join(case_dir, 'postProcessing', 'boundaryVelocity', '0', 'surfaceFieldValue.dat')
    if os.path.isfile(u_src):
        times = []
        u_x = []
        with open(u_src, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('#') or not line:
                    continue
                parts = line.split()
                if len(parts) >= 2:
                    times.append(float(parts[0]))
                    # Handle vector format (x y z) or scalar
                    val = parts[1].strip('()')
                    u_x.append(float(val))
        df = pd.DataFrame({'Time': times, 'U_x': u_x})
        out_path = os.path.join(csv_dir, f'U_{SIGMOID}_{N}.csv')
        df.to_csv(out_path, index=False)
        print(f"  Saved {out_path}")

print("Data collection complete.")

# ============================================================
# Figure 1: X(t) with mesh lines
# ============================================================
print("\nGenerating Figure 1: X(t) with mesh lines...")

def plot_subplot_X_t_with_mesh(ax, sig_func, n_of_elements, density, start_time):
    global rho_L
    rho_L = density_map[density]

    csv_path = os.path.join(csv_dir, f'LiqFracInt_{sig_func}_{n_of_elements}.csv')
    if not os.path.isfile(csv_path):
        print(f"  WARNING: {csv_path} not found")
        return

    X_t = pd.read_csv(csv_path).sort_values('Time')
    position = 1 - X_t['Value'].to_numpy() / 1e-2

    ax.plot(X_t['Time'] + start_time, position, label='Numerical', **num_config)

    each = 100
    ax.scatter(X_t['Time'][::each] + start_time,
               X_t_analytic(X_t['Time'].to_numpy()[::each] + start_time),
               label='Analytical', **num_scat_config)

    mesh = np.arange(0 + 0.5 / n_of_elements, 1, 1 / n_of_elements)
    mask = (mesh > (position[0] - 2.5 / n_of_elements)) & (mesh < position[-1])
    if np.any(mask):
        ax.axhline(mesh[mask][0], **axhline_config, label='Node center')
        for mp in mesh[mask][1:]:
            ax.axhline(mp, **axhline_config)

    ax.set_ylim(0.053, 0.115)
    ax.set_xlabel('Time [s]')
    ax.set_ylabel('Position $X$ [m]')
    ax.legend(loc=4)
    ax.set_title('piecewise linear $\\phi$')

n_elem_fig1 = 128
fig, ax = plt.subplots(1, 1, figsize=(5, 4))
plot_subplot_X_t_with_mesh(ax, SIGMOID, n_elem_fig1, DENSITY_CASE, START_TIME)
plt.tight_layout()
plt.savefig(os.path.join(ROOT_DIR, f'X_t_plots_with_mesh_{SIGMOID}.pdf'))
print(f"  Saved X_t_plots_with_mesh_{SIGMOID}.pdf")
plt.close()

# ============================================================
# Figure 2: Temperature error convergence
# ============================================================
print("\nGenerating Figure 2: Temperature error convergence...")

def plot_subplot_Temp_error(ax, sig_func, n_of_elements_list, density, start_time, read_time):
    global rho_L
    rho_L = density_map[density]

    temp_error = []
    valid_elements = []
    for element in n_of_elements_list:
        adress = os.path.join(csv_dir, f'TemDitr_{sig_func}_{element}', str(read_time), 's1_T.csv')
        if not os.path.isfile(adress):
            print(f"  WARNING: {adress} not found, skipping N={element}")
            continue
        T_numerical = pd.read_csv(adress)
        T_numerical['x'] = T_numerical['x'] * -1 + 0.5
        T_analytical = analytical_temperature_in_domain(T_numerical['x'].to_numpy(), start_time + read_time)
        err = np.linalg.norm(T_numerical['T'].to_numpy() - T_analytical) / element**0.5
        temp_error.append(err)
        valid_elements.append(element)

    if not valid_elements:
        return

    ax.scatter(valid_elements, temp_error, label='$||T - \\hat{T}||_2$', **num_scat_config)

    C_1 = 1e2
    first_order_line = [C_1 * e**-1 for e in valid_elements]
    ax.plot(valid_elements, first_order_line, linestyle='--', label='$\\mathcal{O}(h^1)$', color='green')

    ax.set_xlabel('Grid size $N$')
    ax.set_ylabel('$||T - \\hat{T}||_2$')
    ax.set_yscale('log')
    ax.set_xscale('log')
    ax.set_ylim(0.05, 18)
    ax.legend(loc=0)
    ax.grid(True, linestyle='-.')
    ax.set_title('piecewise linear $\\phi$')

fig, ax = plt.subplots(1, 1, figsize=(5, 4))
plot_subplot_Temp_error(ax, SIGMOID, RESOLUTIONS, DENSITY_CASE, START_TIME, READ_TIME)
plt.tight_layout()
plt.savefig(os.path.join(ROOT_DIR, f'Temp_error_from_mesh_{SIGMOID}.pdf'))
print(f"  Saved Temp_error_from_mesh_{SIGMOID}.pdf")
plt.close()

# ============================================================
# Figure 2b: Front position error convergence
# ============================================================
print("\nGenerating Figure 2b: Front position error convergence...")

def plot_subplot_X_t_error(ax, sig_func, n_of_elements_list, density, start_time, read_time):
    global rho_L
    rho_L = density_map[density]

    x_error = []
    valid_elements = []
    for element in n_of_elements_list:
        csv_path = os.path.join(csv_dir, f'LiqFracInt_{sig_func}_{element}.csv')
        if not os.path.isfile(csv_path):
            print(f"  WARNING: {csv_path} not found, skipping N={element}")
            continue
        X_t_numerical = pd.read_csv(csv_path).sort_values('Time')
        time_values = np.array(X_t_numerical['Time'] + start_time)

        position_numerical = 1 - X_t_numerical['Value'].to_numpy() / 1e-2
        position_analytical = X_t_analytic(time_values)

        error = np.linalg.norm(position_numerical - position_analytical) / len(time_values)**0.5
        x_error.append(error)
        valid_elements.append(element)

    if not valid_elements:
        return

    ax.scatter(valid_elements, x_error, label='$||X - \\hat{X}||_2$', **num_scat_config)

    C_1 = 1e-1
    first_order_line = [C_1 * e**-1 for e in valid_elements]
    ax.plot(valid_elements, first_order_line, linestyle='--', label='$\\mathcal{O}(h^1)$', color='green')

    ax.set_xlabel('Grid size $N$')
    ax.set_ylabel('$||X - \\hat{X}||_2$')
    ax.set_yscale('log')
    ax.set_xscale('log')
    ax.set_ylim(0.00005, 0.05)
    ax.legend(loc=0)
    ax.grid(True, linestyle='-.')
    ax.set_title('piecewise linear $\\phi$')

fig, ax = plt.subplots(1, 1, figsize=(5, 4))
plot_subplot_X_t_error(ax, SIGMOID, RESOLUTIONS, DENSITY_CASE, START_TIME, READ_TIME)
plt.tight_layout()
plt.savefig(os.path.join(ROOT_DIR, f'X_t_error_from_mesh_{SIGMOID}.pdf'))
print(f"  Saved X_t_error_from_mesh_{SIGMOID}.pdf")
plt.close()

# ============================================================
# Figure 3: Boundary velocity U_b(t)
# ============================================================
print("\nGenerating Figure 3: Boundary velocity U_b(t)...")

def plot_subplot_Ub_t(ax, sig_func, n_of_elements, density, start_time):
    global rho_L
    rho_L = density_map[density]

    csv_path = os.path.join(csv_dir, f'U_{sig_func}_{n_of_elements}.csv')
    if not os.path.isfile(csv_path):
        print(f"  WARNING: {csv_path} not found")
        return

    U = pd.read_csv(csv_path).sort_values('Time')
    U_mag = U['U_x'].to_numpy()

    window_size = 100
    smoothed_velocity = pd.Series(U_mag).rolling(window=window_size, center=True).mean()
    each = 50
    ax.scatter(U['Time'].to_numpy()[::each] + start_time,
               smoothed_velocity.to_numpy()[::each],
               label='Averaged numerical', **num_scat_config)

    time_arr = U['Time'].to_numpy() + start_time
    ax.plot(time_arr, -(1 - rho_S / rho_L) * X_dot_t_analytic(time_arr),
            label='Analytical', **anal_config)

    ax.set_xlabel('Time [s]')
    ax.set_ylabel('Velocity $U_b$ [m/s]')
    ax.legend()
    ax.grid(True, linestyle='-.')
    ax.set_title('piecewise linear $\\phi$')

n_elem_fig3 = 1024
fig, ax = plt.subplots(1, 1, figsize=(5, 4))
plot_subplot_Ub_t(ax, SIGMOID, n_elem_fig3, DENSITY_CASE, START_TIME)
plt.tight_layout()
plt.savefig(os.path.join(ROOT_DIR, f'U_t_plots_{SIGMOID}.pdf'))
print(f"  Saved U_t_plots_{SIGMOID}.pdf")
plt.close()

print("\n============================================")
print(" Post-processing complete!")
print("============================================")
PYEOF

# Run the Python post-processing script
python3 "${ROOT_DIR}/${PYTHON_SCRIPT}"

echo ""
echo "============================================="
echo " All done!"
echo "============================================="
