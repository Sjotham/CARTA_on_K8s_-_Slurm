#!/usr/bin/env bash
set -euo pipefail

########################################
# CONFIG (edit to match your cluster)  #
########################################

# Path to the CARTA backend Apptainer image (visible on compute nodes)
IMAGE="${IMAGE:-/data/carta-backend-1.4.0.sif}"

# Base directory for data (must exist on compute node, usually shared)
BASE_DIR="${BASE_DIR:-/data}"

# Default port (can be overridden as first script argument)
DEFAULT_PORT=3002

# Slurm settings
PARTITION="${PARTITION:-}"     # e.g. "compute" or leave empty for default
CPUS_PER_TASK="${CPUS_PER_TASK:-2}"
MEM_PER_TASK="${MEM_PER_TASK:-2G}"
TIME_LIMIT="${TIME_LIMIT:-02:00:00}"   # hh:mm:ss
ACCOUNT="${ACCOUNT:-}"         # if your cluster requires --account
NODELIST="${NODELIST:-}"       # e.g. "vm2" if you want a specific node

########################################
# ARGUMENTS
########################################

PORT="${1:-$DEFAULT_PORT}"

echo "=== Deploying CARTA backend via srun ==="
echo "  Image     : ${IMAGE}"
echo "  Base dir  : ${BASE_DIR}"
echo "  Port      : ${PORT}"
echo

# Quick sanity checks
if [ ! -f "${IMAGE}" ]; then
  echo "ERROR: Image file not found at ${IMAGE}"
  exit 1
fi

if [ ! -d "${BASE_DIR}" ]; then
  echo "ERROR: Base directory ${BASE_DIR} does not exist on the control node."
  echo "       It must also exist (usually via shared storage) on compute nodes."
  exit 1
fi

########################################
# BUILD SRUN OPTIONS
########################################

SRUN_OPTS=(
  --nodes=1
  --ntasks=1
  --cpus-per-task="${CPUS_PER_TASK}"
  --mem="${MEM_PER_TASK}"
  --time="${TIME_LIMIT}"
  --job-name="carta-${PORT}"
  --output="carta-backend-%j.log"
)

if [ -n "${PARTITION}" ]; then
  SRUN_OPTS+=( --partition="${PARTITION}" )
fi

if [ -n "${ACCOUNT}" ]; then
  SRUN_OPTS+=( --account="${ACCOUNT}" )
fi

if [ -n "${NODELIST}" ]; then
  SRUN_OPTS+=( --nodelist="${NODELIST}" )
fi

########################################
# RUN SRUN
########################################

# Export variables so they are visible inside the srun bash -lc environment
export IMAGE BASE_DIR PORT

echo "Running srun..."
echo "  srun ${SRUN_OPTS[*]}"

srun "${SRUN_OPTS[@]}" bash -lc '
  echo "=== CARTA backend job starting on node: $(hostname) ==="
  echo "Image     : ${IMAGE}"
  echo "Base dir  : ${BASE_DIR}"
  echo "Port      : ${PORT}"
  echo

  # If your cluster uses environment modules, you might need:
  # module load apptainer

  # Bind BASE_DIR so carta-backend can see the data directory
  apptainer exec --cleanenv --bind "${BASE_DIR}:${BASE_DIR}" \
    "${IMAGE}" \
    /carta-backend/build/carta_backend \
      port="${PORT}" \
      threads=2 \
      omp_threads=4 \
      base="${BASE_DIR}"
'

echo
echo "=== srun exited ==="
echo "Check the output log with:  ls -1 carta-backend-*.log"
