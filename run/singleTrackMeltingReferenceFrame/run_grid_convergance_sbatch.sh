#!/bin/bash
#
# SBATCH Grid Convergence Study
# Submits each mesh size as a separate SLURM job with dependencies
#
# Usage: ./run_grid_convergence_sbatch.sh [power_dir]
#   e.g., ./run_grid_convergence_sbatch.sh 120W
#

set -e

# ============================================================
# USER CONFIGURATION
# ============================================================
MESH_SIZES=(50 25 20 15 12.5 10)
BASE_CASE="newCases"
PVBATCH="$HOME/paraview/ParaView-5.11.2-MPI-Linux-Python3.9-x86_64/bin/pvbatch"
SCRIPTS_DIR="$HOME/scripts/paraview_scripts"
WORK_DIR="$(pwd)"

POWER_DIR="${1:-.}"  # Optional: run inside a power directory like 120W

if [ "$POWER_DIR" != "." ]; then
    mkdir -p "$POWER_DIR"
    # Copy base case into power dir if not already there
    if [ ! -d "${POWER_DIR}/${BASE_CASE}" ]; then
        cp -r "$BASE_CASE" "${POWER_DIR}/"
    fi
    cd "$POWER_DIR"
    WORK_DIR="$(pwd)"
fi

get_nprocs() {
    local mesh_um=$1
    local need_64
    need_64=$(echo "$mesh_um <= 15" | bc -l)
    if [ "$need_64" -eq 1 ]; then
        echo 64
    else
        echo 32
    fi
}

get_decomp_n() {
    local nprocs=$1
    if [ "$nprocs" -eq 64 ]; then
        echo "(4 8 2)"
    else
        echo "(4 4 2)"
    fi
}

get_nodes_and_tasks() {
    local nprocs=$1
    if [ "$nprocs" -eq 64 ]; then
        echo "2 32"  # 2 nodes, 32 tasks per node
    else
        echo "1 32"  # 1 node, 32 tasks per node
    fi
}

# ============================================================
# Setup all cases first
# ============================================================
echo "Setting up cases..."

for mesh_um in "${MESH_SIZES[@]}"; do
    case_dir="${mesh_um}um"
    nprocs=$(get_nprocs "$mesh_um")
    decomp_n=$(get_decomp_n "$nprocs")

    if [ ! -d "$case_dir" ]; then
        cp -r "$BASE_CASE" "$case_dir"
    fi

    d_h_value="${mesh_um}e-3"
    sed -i "s/^d_h[[:space:]]\+.*$/d_h ${d_h_value};/" "${case_dir}/system/blockMeshDict"
    sed -i "s/^numberOfSubdomains[[:space:]]\+.*$/numberOfSubdomains ${nprocs};/" \
        "${case_dir}/system/decomposeParDict"
    sed -i "s/n[[:space:]]\+(.*)/n               ${decomp_n};/" \
        "${case_dir}/system/decomposeParDict"

    echo "  Setup: ${case_dir} | d_h=${d_h_value} | nprocs=${nprocs} | decomp=${decomp_n}"
done

# ============================================================
# Submit SLURM jobs
# ============================================================
echo ""
echo "Submitting SLURM jobs..."

SIM_JOB_IDS=()

for mesh_um in "${MESH_SIZES[@]}"; do
    case_dir="${mesh_um}um"
    nprocs=$(get_nprocs "$mesh_um")
    read -r nodes ntasks_per_node <<< "$(get_nodes_and_tasks "$nprocs")"

    JOB_NAME="gc_${mesh_um}um"

    # Create the SLURM simulation script
    cat > "${case_dir}/slurm_run.sh" << EOFSLURM
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --partition=amd,intel
#SBATCH --nodes=${nodes}
#SBATCH --ntasks-per-node=${ntasks_per_node}
#SBATCH --time=48:00:00
#SBATCH --output=slurm_%j.out
#SBATCH --error=slurm_%j.err

module purge
module load openfoam/v2406

cd "${WORK_DIR}/${case_dir}"

echo "Starting simulation: ${case_dir} (mesh = ${mesh_um} um)"
echo "Processors: ${nprocs}"
date

## Run the simulation
./Allrun -parallel

## Reconstruct
reconstructPar -fields alpha.metal > log.reconstructPar 2>&1

echo "Simulation complete: ${case_dir}"
date
EOFSLURM

    # Submit simulation job
    SIM_JOB_ID=$(sbatch "${case_dir}/slurm_run.sh" | awk '{print $4}')
    SIM_JOB_IDS+=("$SIM_JOB_ID")
    echo "  Submitted ${case_dir} simulation: Job ID ${SIM_JOB_ID}"

    # Create the SLURM post-processing script (depends on simulation)
    cat > "${case_dir}/slurm_postprocess.sh" << EOFPP
#!/bin/bash
#SBATCH --job-name=pp_${mesh_um}um
#SBATCH --partition=amd,intel
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=04:00:00
#SBATCH --output=slurm_pp_%j.out
#SBATCH --error=slurm_pp_%j.err

cd "${WORK_DIR}/${case_dir}"

echo "Starting post-processing: ${case_dir} (mesh = ${mesh_um} um)"
date

# Melt pool Umax
${PVBATCH} ${SCRIPTS_DIR}/melt_pool_Umax_at_each_time_step.py \
    > log.pvbatch_Umax 2>&1

# Melt pool height
${PVBATCH} ${SCRIPTS_DIR}/melt_pool_height_at_each_time_step.py -r \
    > log.pvbatch_height 2>&1

# Melt pool wasMelted depth
${PVBATCH} ${SCRIPTS_DIR}/melt_pool_wasMelted_depth_at_each_time_step.py -d \
    > log.pvbatch_depth 2>&1

echo "Post-processing complete: ${case_dir}"
date
EOFPP

    # Submit post-processing job with dependency
    PP_JOB_ID=$(sbatch --dependency=afterok:${SIM_JOB_ID} \
        "${case_dir}/slurm_postprocess.sh" | awk '{print $4}')
    echo "  Submitted ${case_dir} post-processing: Job ID ${PP_JOB_ID} (depends on ${SIM_JOB_ID})"

done

# ============================================================
# Submit final analysis job (depends on ALL post-processing)
# ============================================================
ALL_SIM_IDS=$(IFS=:; echo "${SIM_JOB_IDS[*]}")

cat > slurm_analyze.sh << EOFANALYZE
#!/bin/bash
#SBATCH --job-name=gc_analyze
#SBATCH --partition=amd,intel
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=slurm_analyze_%j.out
#SBATCH --error=slurm_analyze_%j.err

cd "${WORK_DIR}"

echo "Running mesh convergence analysis..."
date

module load python
python3 mesh_convergence_analysis.py

echo "Analysis complete."
date
EOFANALYZE

# Build dependency string for all post-processing jobs
ANALYZE_JOB_ID=$(sbatch --dependency=afterany:${ALL_SIM_IDS} \
    slurm_analyze.sh | awk '{print $4}')
echo ""
echo "Submitted analysis job: Job ID ${ANALYZE_JOB_ID}"

echo ""
echo "============================================"
echo "All jobs submitted. Summary:"
echo "============================================"
echo "Mesh sizes: ${MESH_SIZES[*]} um"
echo "Simulation Job IDs: ${SIM_JOB_IDS[*]}"
echo "Analysis Job ID: ${ANALYZE_JOB_ID}"
echo ""
echo "Monitor with: squeue -u \$USER"

