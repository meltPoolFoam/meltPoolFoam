#!/usr/bin/env python3
"""
Mesh Convergence Analysis Script
Processes height_data.csv, depth_data.csv and Umax_data.csv from each
mesh directory.

Expected directory structure:
  [MESH]um/height_data.csv
  [MESH]um/depth_data.csv
  [MESH]um/Umax_data.csv
"""

import os
import sys
import pandas as pd
import numpy as np

# Configuration
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.environ.get(
    "ROOT_DIR",
    os.path.join(SCRIPT_DIR, "_mesh_conv_results"),
)
OUTPUT_FILE = os.environ.get(
    "OUTPUT_FILE",
    os.path.join(ROOT_DIR, "mesh_convergence_results.csv"),
)


def process_simulation_data(root_path):
    results = []

    for mesh_dir in sorted(os.listdir(root_path)):
        mesh_path = os.path.join(root_path, mesh_dir)
        result = process_single_case(mesh_path, mesh_dir)
        if result:
            results.append(result)

    return results


def process_single_case(mesh_path, mesh_dir):
    """Process a single mesh case directory."""

    if not os.path.isdir(mesh_path) or not mesh_dir.endswith('um'):
        return None

    try:
        mesh_val = float(mesh_dir.replace('um', ''))
    except ValueError:
        return None

    height_file = os.path.join(mesh_path, 'height_data.csv')
    depth_file = os.path.join(mesh_path, 'depth_data.csv')
    umax_file = os.path.join(mesh_path, 'Umax_data.csv')

    height_at_076 = np.nan
    depth_avg = np.nan
    umax_avg = np.nan

    # --- Process Height Data ---
    if os.path.exists(height_file):
        try:
            df_h = pd.read_csv(height_file, header=None, names=['time', 'val'])
            df_h = df_h.sort_values('time')
            height_at_076 = np.interp(0.076, df_h['time'], df_h['val'])
        except Exception as e:
            print(f"  Error processing {height_file}: {e}")

    # --- Process Depth Data ---
    if os.path.exists(depth_file):
        try:
            df_d = pd.read_csv(depth_file, header=None, names=['time', 'val'])
            mask = (df_d['time'] >= 0.060) & (df_d['time'] <= 0.07)
            selected_data = df_d.loc[mask, 'val']

            if not selected_data.empty:
                depth_avg = selected_data.mean()
        except Exception as e:
            print(f"  Error processing {depth_file}: {e}")

    # --- Process Umax Data ---
    if os.path.exists(umax_file):
        try:
            df_u = pd.read_csv(umax_file, header=None, names=['time', 'val'])
            mask = (df_u['time'] >= 0.060) & (df_u['time'] <= 0.07)
            selected_data = df_u.loc[mask, 'val']

            if not selected_data.empty:
                umax_avg = selected_data.mean()
        except Exception as e:
            print(f"  Error processing {umax_file}: {e}")

    return {
        'Mesh_um': mesh_val,
        'Height_t0.076': height_at_076,
        'Depth_Avg_t0.06_0.07': depth_avg,
        'Umax_Avg_t0.06_0.07': umax_avg,
    }


if __name__ == "__main__":
    print(f"Processing data in {os.path.abspath(ROOT_DIR)}...")
    data = process_simulation_data(ROOT_DIR)

    if data:
        df = pd.DataFrame(data)

        df = df.sort_values(by='Mesh_um')

        df.to_csv(OUTPUT_FILE, index=False)
        print(f"\nSuccessfully processed {len(df)} simulations.")
        print(f"Results saved to: {OUTPUT_FILE}")
        print("\n" + df.to_string(index=False))
    else:
        print("No matching directories found.")

