#!/usr/bin/env python3
"""
Post-processing script for Stefan 1D convergence study.

Collects simulation results from OpenFOAM postProcessing directories,
compares against the analytical Stefan solution, and produces
convergence plots.

Expected layout (created by run_stefan_convergance.sh):
    1D_stefan{N}/postProcessing/volIntegrate/0/volFieldValue.dat
    1D_stefan{N}/postProcessing/writeTemperature/{time}/s1_T.csv
    1D_stefan{N}/postProcessing/pointSample/0/U
"""

import os
import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
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
# Configuration
# ============================================================
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.environ.get("ROOT_DIR", os.path.join(SCRIPT_DIR, "_stefan_convergance"))
RESOLUTIONS = [16, 32, 64, 128, 256, 512, 1024]
SIGMOID = 'cut'
START_TIME = 100
READ_TIME = 300

# ============================================================
# Physical parameters
# ============================================================
rho_S = 2700.
rho_L = 2400.   # den_change_low
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
    return T_0_t + (T_m - T_0_t) * erf(x / (2 * np.sqrt(alpha_S * time))) \
           / erf(lambda_t * np.sqrt(alpha_L / alpha_S))


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
# Plot style configs
# ============================================================
num_config = {'linestyle': '-', 'linewidth': 2, 'markevery': 20, 'zorder': 2, 'color': 'blue'}
num_scat_config = {'s': 40, 'marker': 'x', 'zorder': 3, 'color': 'black'}
axhline_config = {'linestyle': '--', 'linewidth': 1.3, 'color': 'gray', 'zorder': -1}
anal_config = {'linestyle': '-.', 'linewidth': 2}


# ============================================================
# Data collection from postProcessing
# ============================================================
def collect_liq_frac(case_dir):
    """Read volIntegrate liquid fraction data."""
    src = os.path.join(case_dir, 'postProcessing', 'volIntegrate', '0', 'volFieldValue.dat')
    if not os.path.isfile(src):
        return None
    times, values = [], []
    with open(src, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('#') or not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                times.append(float(parts[0]))
                values.append(float(parts[1]))
    return pd.DataFrame({'Time': times, 'Value': values})


def collect_temperature(case_dir, read_time):
    """Read temperature sample data from writeTemperature function object."""
    sample_dir = os.path.join(case_dir, 'postProcessing', 'writeTemperature', str(read_time))
    if not os.path.isdir(sample_dir):
        return None
    # Look for s1_T.csv (setFormat csv, set named s1, field T)
    csv_path = os.path.join(sample_dir, 's1_T.csv')
    if os.path.isfile(csv_path):
        return pd.read_csv(csv_path)
    # Fallback: search for any temperature file
    for fname in os.listdir(sample_dir):
        fpath = os.path.join(sample_dir, fname)
        if fname.endswith('.csv'):
            return pd.read_csv(fpath)
        if fname.endswith('.xy'):
            data = np.loadtxt(fpath)
            return pd.DataFrame({'x': data[:, 0], 'T': data[:, 1]})
    return None


def collect_velocity(case_dir):
    """Read probe velocity data from pointSample function object."""
    src = os.path.join(case_dir, 'postProcessing', 'pointSample', '0', 'U')
    if not os.path.isfile(src):
        return None
    times, u_x = [], []
    with open(src, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith('#') or not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                times.append(float(parts[0]))
                # Handle vector format (x y z)
                val = parts[1].strip('()')
                u_x.append(float(val))
    return pd.DataFrame({'Time': times, 'U_x': u_x})


# ============================================================
# Figure 1: X(t) with mesh lines
# ============================================================
def plot_X_t_with_mesh(ax, N):
    case_dir = os.path.join(ROOT_DIR, f'1D_stefan{N}')
    df = collect_liq_frac(case_dir)
    if df is None:
        print(f"  WARNING: volIntegrate data not found for N={N}")
        return

    df = df.sort_values('Time')
    position = 1 - df['Value'].to_numpy() / 1e-2

    ax.plot(df['Time'] + START_TIME, position, label='Numerical', **num_config)

    each = 100
    ax.scatter(df['Time'][::each] + START_TIME,
               X_t_analytic(df['Time'].to_numpy()[::each] + START_TIME),
               label='Analytical', **num_scat_config)

    mesh = np.arange(0 + 0.5 / N, 1, 1 / N)
    mask = (mesh > (position[0] - 2.5 / N)) & (mesh < position[-1])
    if np.any(mask):
        ax.axhline(mesh[mask][0], **axhline_config, label='Node center')
        for mp in mesh[mask][1:]:
            ax.axhline(mp, **axhline_config)

    ax.set_ylim(0.053, 0.115)
    ax.set_xlabel('Time [s]')
    ax.set_ylabel('Position $X$ [m]')
    ax.legend(loc=4)
    ax.set_title('piecewise linear $\\phi$')


# ============================================================
# Figure 2: Temperature error convergence
# ============================================================
def plot_temp_error(ax):
    temp_error = []
    valid_elements = []

    for N in RESOLUTIONS:
        case_dir = os.path.join(ROOT_DIR, f'1D_stefan{N}')
        df = collect_temperature(case_dir, READ_TIME)
        if df is None:
            print(f"  WARNING: temperature data not found for N={N}")
            continue
        df['x'] = df['x'] * -1 + 0.5
        T_analytical = analytical_temperature_in_domain(
            df['x'].to_numpy(), START_TIME + READ_TIME)
        err = np.linalg.norm(df['T'].to_numpy() - T_analytical) / N**0.5
        temp_error.append(err)
        valid_elements.append(N)

    if not valid_elements:
        return

    ax.scatter(valid_elements, temp_error,
               label='$||T - \\hat{T}||_2$', **num_scat_config)

    C_1 = 1e2
    first_order = [C_1 * e**-1 for e in valid_elements]
    ax.plot(valid_elements, first_order, linestyle='--',
            label='$\\mathcal{O}(h^1)$', color='green')

    ax.set_xlabel('Grid size $N$')
    ax.set_ylabel('$||T - \\hat{T}||_2$')
    ax.set_yscale('log')
    ax.set_xscale('log')
    ax.set_ylim(0.05, 18)
    ax.legend(loc=0)
    ax.grid(True, linestyle='-.')
    ax.set_title('piecewise linear $\\phi$')


# ============================================================
# Figure 2b: Front position error convergence
# ============================================================
def plot_X_t_error(ax):
    x_error = []
    valid_elements = []

    for N in RESOLUTIONS:
        case_dir = os.path.join(ROOT_DIR, f'1D_stefan{N}')
        df = collect_liq_frac(case_dir)
        if df is None:
            print(f"  WARNING: volIntegrate data not found for N={N}")
            continue
        df = df.sort_values('Time')
        time_values = np.array(df['Time'] + START_TIME)
        position_numerical = 1 - df['Value'].to_numpy() / 1e-2
        position_analytical = X_t_analytic(time_values)
        error = np.linalg.norm(position_numerical - position_analytical) / len(time_values)**0.5
        x_error.append(error)
        valid_elements.append(N)

    if not valid_elements:
        return

    ax.scatter(valid_elements, x_error,
               label='$||X - \\hat{X}||_2$', **num_scat_config)

    C_1 = 1e-1
    first_order = [C_1 * e**-1 for e in valid_elements]
    ax.plot(valid_elements, first_order, linestyle='--',
            label='$\\mathcal{O}(h^1)$', color='green')

    ax.set_xlabel('Grid size $N$')
    ax.set_ylabel('$||X - \\hat{X}||_2$')
    ax.set_yscale('log')
    ax.set_xscale('log')
    ax.set_ylim(0.00005, 0.05)
    ax.legend(loc=0)
    ax.grid(True, linestyle='-.')
    ax.set_title('piecewise linear $\\phi$')


# ============================================================
# Figure 3: Boundary velocity U_b(t)
# ============================================================
def plot_Ub_t(ax, N):
    case_dir = os.path.join(ROOT_DIR, f'1D_stefan{N}')
    df = collect_velocity(case_dir)
    if df is None:
        print(f"  WARNING: velocity data not found for N={N}")
        return

    df = df.sort_values('Time')
    U_mag = df['U_x'].to_numpy()

    window_size = 100
    smoothed = pd.Series(U_mag).rolling(window=window_size, center=True).mean()
    each = 50
    ax.scatter(df['Time'].to_numpy()[::each] + START_TIME,
               smoothed.to_numpy()[::each],
               label='Averaged numerical', **num_scat_config)

    time_arr = df['Time'].to_numpy() + START_TIME
    ax.plot(time_arr, -(1 - rho_S / rho_L) * X_dot_t_analytic(time_arr),
            label='Analytical', **anal_config)

    ax.set_xlabel('Time [s]')
    ax.set_ylabel('Velocity $U_b$ [m/s]')
    ax.legend()
    ax.grid(True, linestyle='-.')
    ax.set_title('piecewise linear $\\phi$')


# ============================================================
# Main
# ============================================================
def main():
    if not os.path.isdir(ROOT_DIR):
        print(f"ERROR: work directory not found: {ROOT_DIR}", file=sys.stderr)
        sys.exit(1)

    # Figure 1: X(t) with mesh lines (N=128)
    print("Generating Figure 1: X(t) with mesh lines...")
    fig, ax = plt.subplots(1, 1, figsize=(5, 4))
    plot_X_t_with_mesh(ax, 128)
    plt.tight_layout()
    out = os.path.join(ROOT_DIR, f'X_t_plots_with_mesh_{SIGMOID}.pdf')
    plt.savefig(out)
    print(f"  Saved {out}")
    plt.close()

    # Figure 2: Temperature error convergence
    print("Generating Figure 2: Temperature error convergence...")
    fig, ax = plt.subplots(1, 1, figsize=(5, 4))
    plot_temp_error(ax)
    plt.tight_layout()
    out = os.path.join(ROOT_DIR, f'Temp_error_from_mesh_{SIGMOID}.pdf')
    plt.savefig(out)
    print(f"  Saved {out}")
    plt.close()

    # Figure 2b: Front position error convergence
    print("Generating Figure 2b: Front position error convergence...")
    fig, ax = plt.subplots(1, 1, figsize=(5, 4))
    plot_X_t_error(ax)
    plt.tight_layout()
    out = os.path.join(ROOT_DIR, f'X_t_error_from_mesh_{SIGMOID}.pdf')
    plt.savefig(out)
    print(f"  Saved {out}")
    plt.close()

    # Figure 3: Boundary velocity (N=1024)
    print("Generating Figure 3: Boundary velocity U_b(t)...")
    fig, ax = plt.subplots(1, 1, figsize=(5, 4))
    plot_Ub_t(ax, 1024)
    plt.tight_layout()
    out = os.path.join(ROOT_DIR, f'U_t_plots_{SIGMOID}.pdf')
    plt.savefig(out)
    print(f"  Saved {out}")
    plt.close()

    print("\nPost-processing complete!")


if __name__ == "__main__":
    main()
