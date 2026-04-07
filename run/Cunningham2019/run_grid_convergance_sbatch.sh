#!/bin/bash
#
# SBATCH Grid Convergence Study - Cunningham2019
# Submits each mesh size as a separate SLURM job with dependencies
#
# Usage: cd run/Cunningham2019 && ./run_grid_convergance_sbatch.sh [--beam 47.5]
#
# Mesh-size clones, gathered results and the final PDF all live inside
#   run/Cunningham2019/mesh_conv_results/
# so they don't clutter run/ alongside unrelated cases.
#
# Beam variants:
#   (default)        70 um beam, timeStop=2.0e-3, endTime=2.2e-3
#                    -> case dirs <size>um/, results/, mesh_convergence_Cunningham2019.pdf
#   --beam 47.5      47.5 um beam, timeStop=0.7e-3, endTime=0.8e-3
#                    -> case dirs <size>um_47p5umBeam/,
#                       results_47p5umBeam/,
#                       mesh_convergence_Cunningham2019_47p5umBeam.pdf
#

set -e

# ============================================================
# USER CONFIGURATION
# ============================================================
MESH_SIZES=(12.5 6.25 5)
SCRIPTS_DIR="$HOME/scripts/paraview_scripts"
OPENFOAM_MODULE="openfoam/v2406"
PARAVIEW_MODULE="paraview/5.13.3-osmesa"

# ---- Beam variant -------------------------------------------------
# Empty BEAM_TAG = default (70 um) — no laser/controlDict patches.
BEAM_TAG=""
PATCH_BEAM=0
BEAM_RADIUS=""
BEAM_TIMESTOP=""
BEAM_ENDTIME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --beam)
            shift
            beam_um="$1"
            case "$beam_um" in
                47.5)
                    BEAM_TAG="_47p5umBeam"
                    PATCH_BEAM=1
                    BEAM_RADIUS="47.5e-6"
                    BEAM_TIMESTOP="0.7e-3"
                    BEAM_ENDTIME="0.8e-3"
                    ;;
                70|"")
                    : # default — no patch
                    ;;
                *)
                    echo "ERROR: unsupported --beam value: $beam_um" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Resolve paths from the script's own location so it works no matter
# where the user invokes it from.
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"   # .../run/Cunningham2019
WORK_DIR="${CASE_DIR}/mesh_conv_results"     # all study artifacts live here
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Items copied from the case template into each <size>um/ clone.
CASE_TEMPLATE_ITEMS=(0 Allclean Allrun constant system)

get_nprocs() {
    local mesh_um=$1
    local need_64
    need_64=$(echo "$mesh_um <= 6.25" | bc -l)
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
    case_dir="${mesh_um}um${BEAM_TAG}"
    nprocs=$(get_nprocs "$mesh_um")
    decomp_n=$(get_decomp_n "$nprocs")

    if [ ! -d "$case_dir" ]; then
        mkdir -p "$case_dir"
        for item in "${CASE_TEMPLATE_ITEMS[@]}"; do
            cp -r "${CASE_DIR}/${item}" "${case_dir}/"
        done
    fi

    d_fine_value="${mesh_um}"
    sed -i "s/^d_fine[[:space:]]\+.*$/d_fine ${d_fine_value};/" "${case_dir}/system/blockMeshDict"
    sed -i "s/^numberOfSubdomains[[:space:]]\+.*$/numberOfSubdomains ${nprocs};/" \
        "${case_dir}/system/decomposeParDict"
    sed -i "s/n[[:space:]]\+(.*)/n               ${decomp_n};/" \
        "${case_dir}/system/decomposeParDict"

    if [ "$PATCH_BEAM" -eq 1 ]; then
        # constant/laserProperties: radius and timeStop
        sed -i -E "s|^radius[[:space:]]+[^/;]+;|radius          ${BEAM_RADIUS};|" \
            "${case_dir}/constant/laserProperties"
        sed -i -E "s|^timeStop[[:space:]]+[^/;]+;|timeStop        ${BEAM_TIMESTOP};|" \
            "${case_dir}/constant/laserProperties"
        # system/controlDict: endTime
        sed -i -E "s|^endTime[[:space:]]+[^;]+;|endTime         ${BEAM_ENDTIME};|" \
            "${case_dir}/system/controlDict"
        echo "  Setup: ${case_dir} | d_fine=${d_fine_value} | nprocs=${nprocs} | decomp=${decomp_n} | radius=${BEAM_RADIUS} timeStop=${BEAM_TIMESTOP} endTime=${BEAM_ENDTIME}"
    else
        echo "  Setup: ${case_dir} | d_fine=${d_fine_value} | nprocs=${nprocs} | decomp=${decomp_n}"
    fi
done

# ============================================================
# Submit SLURM jobs
# ============================================================
echo ""
echo "Submitting SLURM jobs..."

SIM_JOB_IDS=()

for mesh_um in "${MESH_SIZES[@]}"; do
    case_dir="${mesh_um}um${BEAM_TAG}"
    nprocs=$(get_nprocs "$mesh_um")
    read -r nodes ntasks_per_node <<< "$(get_nodes_and_tasks "$nprocs")"

    JOB_NAME="gc_${mesh_um}um${BEAM_TAG}"

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
#SBATCH --job-name=pp_${mesh_um}um${BEAM_TAG}
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

# --- Run Cunningham post-processing scripts ---------------------------------
pvbatch ${SCRIPTS_DIR}/melt_pool_surface_depression_at_each_time_step.py -r \
    > log.pvbatch_depression 2>&1
pvbatch ${SCRIPTS_DIR}/melt_pool_depth_at_each_time_step.py -d \
    > log.pvbatch_depth 2>&1
pvbatch ${SCRIPTS_DIR}/melt_pool_width_at_each_time_step.py -d \
    > log.pvbatch_width 2>&1

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

ANALYZE_SLURM="slurm_analyze${BEAM_TAG}.sh"
cat > "${ANALYZE_SLURM}" << EOFANALYZE
#!/bin/bash
#SBATCH --job-name=gc_analyze${BEAM_TAG}
#SBATCH --partition=amd,intel
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:30:00
#SBATCH --output=slurm_analyze_%j.out
#SBATCH --error=slurm_analyze_%j.err

cd "${WORK_DIR}"

echo "Running mesh convergence analysis..."
date

# Gather per-mesh CSVs into a flat results${BEAM_TAG}/ directory
# with the mesh size as filename prefix, so the plotting script
# can pick them up uniformly.
RESULTS_DIR="${WORK_DIR}/results${BEAM_TAG}"
mkdir -p "\${RESULTS_DIR}"
for mesh_um in ${MESH_SIZES[*]}; do
    case_dir="\${mesh_um}um${BEAM_TAG}"
    for csv in "\${case_dir}"/*_data.csv; do
        [ -f "\$csv" ] || continue
        base="\$(basename "\$csv")"
        cp "\$csv" "\${RESULTS_DIR}/\${mesh_um}um_\${base}"
    done
done

module load python
RESULTS_DIR="\${RESULTS_DIR}" \\
OUTPUT_PLOT="${WORK_DIR}/mesh_convergence_Cunningham2019${BEAM_TAG}.pdf" \\
    python3 ${CASE_DIR}/mesh_convergance_analysis.py

echo "Analysis complete."
date
EOFANALYZE

# Build dependency string for all post-processing jobs
ANALYZE_JOB_ID=$(sbatch --dependency=afterany:${ALL_SIM_IDS} \
    "${ANALYZE_SLURM}" | awk '{print $4}')
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
