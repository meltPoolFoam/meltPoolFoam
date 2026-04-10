#!/usr/bin/env python3
"""
Post-processing script for horizontal solidification 2D convergence study.
Plots relative mass error vs time for two tau correction cases
(correction ON vs OFF) across multiple mesh resolutions.

Expected layout (created by run_hor_sol_convergance.sh):
    mass_convergence_csv/mass_{corr|nocorr}_{N}.csv
    mass_convergence_csv/initial_mass_{corr|nocorr}_{N}.txt
"""

import os
import sys
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.colors as mcolors

# ============================================================
# Configuration
# ============================================================
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.environ.get("ROOT_DIR", os.path.join(SCRIPT_DIR, "_horiz_sol_convergance"))
RESOLUTIONS = [16, 32, 64, 128, 256]

TAU_CASES = {
    'corr':   r'$\tau_{\mathrm{corr}} = \Delta t$ (correction ON)',
    'nocorr': r'$\tau_{\mathrm{corr}} = 10^{10}$ (correction OFF)',
}

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
plt.rcParams['legend.fontsize'] = 12
plt.rcParams['figure.titlesize'] = 20

COLORS = list(mcolors.TABLEAU_COLORS.values())
LINESTYLES = ['-', '--', '-.', ':', (0, (3, 1, 1, 1))]

CSV_DIR = os.path.join(ROOT_DIR, 'mass_convergence_csv')


def read_case_data(tau_key, N):
    """Read mass CSV and initial mass for a given tau case and resolution."""
    mass_csv = os.path.join(CSV_DIR, f'mass_{tau_key}_{N}.csv')
    init_mass_file = os.path.join(CSV_DIR, f'initial_mass_{tau_key}_{N}.txt')

    if not os.path.isfile(mass_csv):
        return None, None

    df = pd.read_csv(mass_csv)
    if df.empty:
        return None, None

    if os.path.isfile(init_mass_file):
        with open(init_mass_file, 'r') as f:
            initial_mass = float(f.read().strip())
    else:
        initial_mass = df['Mass'].iloc[0]

    return df, initial_mass


def plot_relative_mass_error(output_path):
    """Relative mass error vs time (one subplot per tau case)."""
    print("Generating relative mass error convergence plots...")
    fig, axes = plt.subplots(1, 2, figsize=(12, 5), sharey=True)

    for ax_idx, (tau_key, tau_label) in enumerate(TAU_CASES.items()):
        ax = axes[ax_idx]
        for res_idx, N in enumerate(RESOLUTIONS):
            df, initial_mass = read_case_data(tau_key, N)
            if df is None:
                print(f"  skip: mass_{tau_key}_{N}.csv not found")
                continue
            relative_error = (df['Mass'] - initial_mass) / initial_mass * 100.0
            ax.plot(df['Time'], relative_error,
                    label=f'N = {N}',
                    color=COLORS[res_idx % len(COLORS)],
                    linestyle=LINESTYLES[res_idx % len(LINESTYLES)],
                    linewidth=2)
        ax.set_xlabel('Time [s]')
        if ax_idx == 0:
            ax.set_ylabel('Relative Change in Mass [%]')
        ax.set_title(tau_label)
        ax.legend(loc='best', fontsize=10)
        ax.grid(True, linestyle='-.', alpha=0.7)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    print(f"  Saved {output_path}")
    plt.close()


def plot_abs_relative_mass_error(output_path):
    """Absolute relative mass error vs time (log scale y)."""
    print("Generating absolute relative mass error plots...")
    fig, axes = plt.subplots(1, 2, figsize=(12, 5), sharey=True)

    for ax_idx, (tau_key, tau_label) in enumerate(TAU_CASES.items()):
        ax = axes[ax_idx]
        for res_idx, N in enumerate(RESOLUTIONS):
            df, initial_mass = read_case_data(tau_key, N)
            if df is None:
                continue
            abs_error = np.abs((df['Mass'] - initial_mass) / initial_mass * 100.0)
            abs_error = abs_error.replace(0, np.nan)
            ax.plot(df['Time'], abs_error,
                    label=f'N = {N}',
                    color=COLORS[res_idx % len(COLORS)],
                    linestyle=LINESTYLES[res_idx % len(LINESTYLES)],
                    linewidth=2)
        ax.set_xlabel('Time [s]')
        if ax_idx == 0:
            ax.set_ylabel('|Relative Change in Mass| [%]')
        ax.set_yscale('log')
        ax.set_title(tau_label)
        ax.legend(loc='best', fontsize=10)
        ax.grid(True, linestyle='-.', alpha=0.7)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    print(f"  Saved {output_path}")
    plt.close()


def plot_error_vs_resolution(output_path, use_max=False):
    """Final or max mass error vs mesh resolution."""
    label_y = 'Max |Relative Mass Error| [%]' if use_max else \
              '|Relative Mass Error| at final time [%]'
    print(f"Generating {('max' if use_max else 'final')} mass error vs resolution...")

    fig, ax = plt.subplots(1, 1, figsize=(6, 5))
    all_valid_N = []
    all_errors = []

    for tau_key, tau_label in TAU_CASES.items():
        errors = []
        valid_N = []
        for N in RESOLUTIONS:
            df, initial_mass = read_case_data(tau_key, N)
            if df is None:
                continue
            rel = np.abs((df['Mass'] - initial_mass) / initial_mass * 100.0)
            err = float(rel.max()) if use_max else float(rel.iloc[-1])
            errors.append(err)
            valid_N.append(N)

        if valid_N:
            marker = 'o' if tau_key == 'corr' else 's'
            ax.plot(valid_N, errors, marker=marker, markersize=8,
                    linewidth=2, label=tau_label)
            if not all_valid_N:
                all_valid_N = valid_N
                all_errors = errors

    if all_valid_N and all_errors:
        N_arr = np.array(all_valid_N, dtype=float)
        C1 = all_errors[0] * all_valid_N[0]
        ax.plot(N_arr, C1 / N_arr, 'k--', linewidth=1.5, alpha=0.5,
                label=r'$\mathcal{O}(h^1)$')
        C2 = all_errors[0] * all_valid_N[0]**2
        ax.plot(N_arr, C2 / N_arr**2, 'k:', linewidth=1.5, alpha=0.5,
                label=r'$\mathcal{O}(h^2)$')

    ax.set_xlabel('Grid size $N$')
    ax.set_ylabel(label_y)
    ax.set_xscale('log')
    ax.set_yscale('log')
    ax.legend(loc='best')
    ax.grid(True, linestyle='-.', alpha=0.7)
    if all_valid_N:
        ax.set_xticks(all_valid_N)
        ax.set_xticklabels([str(n) for n in all_valid_N])

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    print(f"  Saved {output_path}")
    plt.close()


def main():
    if not os.path.isdir(CSV_DIR):
        print(f"ERROR: CSV directory not found: {CSV_DIR}", file=sys.stderr)
        sys.exit(1)

    plot_relative_mass_error(
        os.path.join(ROOT_DIR, 'relative_mass_error_vs_time.pdf'))
    plot_abs_relative_mass_error(
        os.path.join(ROOT_DIR, 'abs_relative_mass_error_vs_time.pdf'))
    plot_error_vs_resolution(
        os.path.join(ROOT_DIR, 'mass_error_convergence.pdf'), use_max=False)
    plot_error_vs_resolution(
        os.path.join(ROOT_DIR, 'max_mass_error_convergence.pdf'), use_max=True)

    print("\nPost-processing complete!")


if __name__ == "__main__":
    main()
