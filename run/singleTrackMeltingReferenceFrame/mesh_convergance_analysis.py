#!/usr/bin/env python3
"""
Mesh Convergence Analysis Script
Processes height_data.csv and depth_data.csv from each mesh directory.

Expected directory structure:
  [POWER_DIR]/[MESH]um/height_data.csv
  [POWER_DIR]/[MESH]um/depth_data.csv

Or flat structure:
  [MESH]um/height_data.csv
  [MESH]um/depth_data.csv
"""

import os
import sys
import pandas as pd
import numpy as np

# Configuration
ROOT_DIR = "."
OUTPUT_FILE = "mesh_convergence_results.csv"


def process_simulation_data(root_path):
    results = []

    entries = os.listdir(root_path)

    # Check if we have power directories (e.g., 120W/) or flat mesh dirs (e.g., 50um/)
    has_power_dirs = any(
        e.endswith('W') and os.path.isdir(os.path.join(root_path, e))
        for e in entries
    )

    if has_power_dirs:
        # Nested structure: POWER/MESH
        for power_dir in sorted(entries):
            power_path = os.path.join(root_path, power_dir)

            if not os.path.isdir(power_path) or not power_dir.endswith('W'):
                continue

            try:
                power_val = float(power_dir.replace('W', ''))
            except ValueError:
                continue

            for mesh_dir in sorted(os.listdir(power_path)):
                mesh_path = os.path.join(power_path, mesh_dir)
                result = process_single_case(mesh_path, mesh_dir, power_val)
                if result:
                    results.append(result)
    else:
        # Flat structure: just MESH directories
        for mesh_dir in sorted(entries):
            mesh_path = os.path.join(root_path, mesh_dir)
            result = process_single_case(mesh_path, mesh_dir, power_val=np.nan)
            if result:
                results.append(result)

    return results


def process_single_case(mesh_path, mesh_dir, power_val):
    """Process a single mesh case directory."""

    if not os.path.isdir(mesh_path) or not mesh_dir.endswith('um'):
        return None

    try:
        mesh_val = float(mesh_dir.replace('um', ''))
    except ValueError:
        return None

    height_file = os.path.join(mesh_path, 'height_data.csv')
    depth_file = os.path.join(mesh_path, 'depth_data.csv')

    height_at_076 = np.nan
    depth_avg = np.nan

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

    result = {
        'Mesh_um': mesh_val,
        'Height_t0.076': height_at_076,
        'Depth_Avg_t0.06_0.07': depth_avg
    }

    if not np.isnan(power_val):
        result['Power_W'] = power_val

    return result


if __name__ == "__main__":
    print(f"Processing data in {os.path.abspath(ROOT_DIR)}...")
    data = process_simulation_data(ROOT_DIR)

    if data:
        df = pd.DataFrame(data)

        # Sort columns
        sort_cols = []
        if 'Power_W' in df.columns:
            sort_cols.append('Power_W')
        sort_cols.append('Mesh_um')
        df = df.sort_values(by=sort_cols)

        df.to_csv(OUTPUT_FILE, index=False)
        print(f"\nSuccessfully processed {len(df)} simulations.")
        print(f"Results saved to: {OUTPUT_FILE}")
        print("\n" + df.to_string(index=False))
    else:
        print("No matching directories found.")

