#!/usr/bin/env python3
"""
Mesh Convergence Analysis - Cunningham2019

Reads per-mesh post-processing CSVs (depth / width / surface depression
time series) gathered into a flat results/ directory by the SLURM
driver, and produces a single multi-panel PDF overlaying all mesh
sizes.

Expected layout (created by run_grid_convergance_sbatch.sh):
    results/<mesh>um_depth_data.csv
    results/<mesh>um_width_data.csv
    results/<mesh>um_depression_data.csv  (or *_surface_depression_data.csv)

The exact filenames produced by the pvbatch scripts in
tools/paraview_scripts may differ; "depth", "width" and
"depression" substring matches are used so the script tolerates
small naming variations.
"""

import os
import re
import sys
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Configuration
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DIRECTORY_PATH = os.environ.get(
    "RESULTS_DIR",
    os.path.join(SCRIPT_DIR, "mesh_conv_results", "results"),
)
OUTPUT_PLOT = os.environ.get(
    "OUTPUT_PLOT",
    os.path.join(
        os.path.dirname(DIRECTORY_PATH),
        "mesh_convergence_Cunningham2019.pdf",
    ),
)

# Filename pattern: "<mesh>um_<rest>_data.csv", e.g. "6.25um_depth_data.csv"
MESH_PATTERN = re.compile(r"^(\d+(?:\.\d+)?)um_.*_data\.csv$")


def mesh_key(filename):
    m = MESH_PATTERN.match(filename)
    return m.group(1) if m else None


def main():
    if not os.path.isdir(DIRECTORY_PATH):
        print(f"ERROR: results directory not found: {DIRECTORY_PATH}",
              file=sys.stderr)
        sys.exit(1)

    depth_data = {}
    width_data = {}
    depression_data = {}

    for filename in sorted(os.listdir(DIRECTORY_PATH)):
        if not filename.endswith(".csv"):
            continue

        key = mesh_key(filename)
        if key is None:
            print(f"  skip (no mesh prefix): {filename}")
            continue

        path = os.path.join(DIRECTORY_PATH, filename)
        try:
            df = pd.read_csv(path)
        except Exception as e:
            print(f"  error reading {filename}: {e}")
            continue

        lower = filename.lower()
        if "depression" in lower:
            depression_data[key] = df
        elif "depth" in lower:
            depth_data[key] = df
        elif "width" in lower:
            width_data[key] = df

    if not (depth_data or width_data or depression_data):
        print("ERROR: no recognized CSVs found in "
              f"{DIRECTORY_PATH}", file=sys.stderr)
        sys.exit(1)

    fig, axes = plt.subplots(1, 3, figsize=(18, 6))
    fig.suptitle("Cunningham2019 — mesh convergence", fontsize=16)

    def sorted_items(d):
        # Sort by numeric mesh size (ascending = coarse → fine)
        return sorted(d.items(), key=lambda kv: float(kv[0]))

    # --- Depth ---
    ax = axes[0]
    for key, df in sorted_items(depth_data):
        x_col, y_col = df.columns[0], df.columns[1]
        ax.plot(df[x_col], df[y_col],
                label=f"{key} um", marker="o", markersize=4)
    ax.set_title("Depth")
    ax.set_xlabel("time [s]")
    ax.set_ylabel("Depth [m]")
    ax.set_ylim(-270e-6, 10e-6)
    ax.set_xlim(-1e-4, 2.2e-3)
    if depth_data:
        ax.legend()
    ax.grid(True, alpha=0.3)

    # --- Width ---
    ax = axes[1]
    for key, df in sorted_items(width_data):
        x_col, y_col = df.columns[0], df.columns[1]
        ax.plot(df[x_col], df[y_col],
                label=f"{key} um", marker="s", markersize=4)
    ax.set_title("Width")
    ax.set_xlabel("time [s]")
    ax.set_ylabel("Width [m]")
    ax.set_ylim(50e-6, 500e-6)
    ax.set_xlim(-1e-4, 2.2e-3)
    if width_data:
        ax.legend()
    ax.grid(True, alpha=0.3)

    # --- Surface depression ---
    ax = axes[2]
    for key, df in sorted_items(depression_data):
        x_col, y_col = df.columns[0], df.columns[1]
        ax.plot(df[x_col], df[y_col],
                label=f"{key} um", marker="^", markersize=4)
    ax.set_title("Surface depression")
    ax.set_xlabel("time [s]")
    ax.set_ylabel("Depression [m]")
    ax.set_ylim(-270e-6, 10e-6)
    ax.set_xlim(-1e-4, 2.2e-3)
    if depression_data:
        ax.legend()
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(OUTPUT_PLOT, dpi=300, bbox_inches="tight")
    print(f"Plot saved: {OUTPUT_PLOT}")


if __name__ == "__main__":
    main()
