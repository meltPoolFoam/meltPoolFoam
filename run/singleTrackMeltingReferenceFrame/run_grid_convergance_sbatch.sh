#!/bin/bash
#
# SBATCH Grid Convergence Study
# Submits each mesh size as a separate SLURM job with dependencies
#
# Usage: cd run/singleTrackMeltingReferenceFrame && \
#        ./run_grid_convergance_sbatch.sh [power_dir]
#   e.g., ./run_grid_convergance_sbatch.sh 120W
#
# All study artifacts (mesh-size clones, gathered results, analysis
# output) live inside the case directory under mesh_conv_results/ so
# they don't clutter run/. With a POWER_DIR arg they live one level
# deeper at mesh_conv_results/<POWER_DIR>/.
#

set -e

# ============================================================
# USER CONFIGURATION
# ============================================================
MESH_SIZES=(50 25 20 15 12.5 10)
DELTAT_VALUES=(5.0e-7 2.5e-7 2.0e-7 1.5e-7 1e-7 1e-7)
MAXDELTAT_VALUES=(2e-6 1.2e-6 1e-6 8e-7 5e-7 5e-7)

SCRIPTS_DIR="$HOME/scripts/paraview_scripts"
OPENFOAM_MODULE="openfoam/v2406"
PARAVIEW_MODULE="paraview/5.13.3-osmesa"

# Resolve paths from the script's own location so it works no matter
# where the user invokes it from.
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"   # .../run/singleTrackMeltingReferenceFrame
WORK_DIR="${CASE_DIR}/mesh_conv_results"     # all study artifacts live here

# Items copied from the case template into each <size>um/ clone.
CASE_TEMPLATE_ITEMS=(0 Allclean Allrun constant system)

POWER_DIR="${1:-.}"  # Optional: nest under a power directory like 120W

if [ "$POWER_DIR" != "." ]; then
    WORK_DIR="${WORK_DIR}/${POWER_DIR}"
fi

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

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

for idx in "${!MESH_SIZES[@]}"; do
    mesh_um="${MESH_SIZES[$idx]}"
    deltaT_value="${DELTAT_VALUES[$idx]}"
    maxDeltaT_value="${MAXDELTAT_VALUES[$idx]}"
    case_dir="${mesh_um}um"
    nprocs=$(get_nprocs "$mesh_um")
    decomp_n=$(get_decomp_n "$nprocs")

    if [ ! -d "$case_dir" ]; then
        mkdir -p "$case_dir"
        for item in "${CASE_TEMPLATE_ITEMS[@]}"; do
            cp -r "${CASE_DIR}/${item}" "${case_dir}/"
        done
    fi

    d_h_value="${mesh_um}e-3"
    sed -i "s/^d_h[[:space:]]\+.*$/d_h ${d_h_value};/" "${case_dir}/system/blockMeshDict"
    sed -i "s/^numberOfSubdomains[[:space:]]\+.*$/numberOfSubdomains ${nprocs};/" \
        "${case_dir}/system/decomposeParDict"
    sed -i "s/n[[:space:]]\+(.*)/n               ${decomp_n};/" \
        "${case_dir}/system/decomposeParDict"

    sed -i -E "s|^deltaT[[:space:]]+[^;]+;|deltaT          ${deltaT_value};|" \
        "${case_dir}/system/controlDict"
    sed -i -E "s|^maxDeltaT[[:space:]]+[^;]+;|maxDeltaT       ${maxDeltaT_value};|" \
        "${case_dir}/system/controlDict"

    echo "  Setup: ${case_dir} | d_h=${d_h_value} | dt=${deltaT_value} maxdt=${maxDeltaT_value} | nprocs=${nprocs} | decomp=${decomp_n}"
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
module load ${OPENFOAM_MODULE}

cd "${WORK_DIR}/${case_dir}"

echo "Starting simulation: ${case_dir} (mesh = ${mesh_um} um)"
echo "Processors: ${nprocs}"
date

## Run the simulation
./Allrun -parallel

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

# --- Reconstruct alpha.metal -------------------------------------------------
module purge
module load ${OPENFOAM_MODULE}
reconstructPar -fields alpha.metal > log.reconstructPar 2>&1

# --- Load ParaView module and verify pvbatch ---------------------------------
module load ${PARAVIEW_MODULE}
if ! command -v pvbatch >/dev/null 2>&1; then
    echo "ERROR: pvbatch not available after loading ${PARAVIEW_MODULE}" >&2
    exit 1
fi

# Melt pool Umax
pvbatch ${SCRIPTS_DIR}/melt_pool_Umax_at_each_time_step.py \
    > log.pvbatch_Umax 2>&1

# Melt pool height
pvbatch ${SCRIPTS_DIR}/melt_pool_height_at_each_time_step.py -r \
    > log.pvbatch_height 2>&1

# Melt pool wasMelted depth
pvbatch ${SCRIPTS_DIR}/melt_pool_wasMelted_depth_at_each_time_step.py -d \
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
python3 ${CASE_DIR}/mesh_convergance_analysis.py

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

