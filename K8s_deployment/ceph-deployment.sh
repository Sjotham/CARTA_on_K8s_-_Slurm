#!/usr/bin/env bash
set -euo pipefail

# ---------- Config (change if needed) ----------
PROFILE="${PROFILE:-minikube}"            # Minikube profile name
NODE="${NODE:-}"                          # If empty, uses default node
DISK_DIR="/mnt/disks"
DISK_IMG="${DISK_DIR}/mydisk.img"
DISK_SIZE_GB="${DISK_SIZE_GB:-10}"        # Size of the disk image in GB
NBD_DEV="${NBD_DEV:-/dev/nbd0}"

ROOK_REPO="${ROOK_REPO:-https://github.com/rook/rook.git}"
ROOK_BRANCH="${ROOK_BRANCH:-}"            # e.g., v1.14.7 (empty = repo default)
ROOK_NS="${ROOK_NS:-rook-ceph}"

# ---------- Helpers ----------
log() { echo -e "\n\033[1;34m### $*\033[0m"; }
warn() { echo -e "\n\033[1;33m!!! $*\033[0m"; }
die() { echo -e "\n\033[1;31mxxx $*\033[0m"; exit 1; }

mm_ssh() {
  # Run a command inside Minikube node (supports multi-node if NODE is set)
  if [[ -n "${NODE}" ]]; then
    minikube -p "${PROFILE}" ssh -n "${NODE}" -- "$@"
  else
    minikube -p "${PROFILE}" ssh -- "$@"
  fi
}

# ---------- Pre-flight checks ----------
command -v minikube >/dev/null || die "minikube not found"
command -v kubectl  >/dev/null || die "kubectl not found"

log "Minikube status"
minikube -p "${PROFILE}" status || die "Minikube profile '${PROFILE}' is not running"

# ---------- Create & attach disk image inside Minikube ----------
log "Creating ${DISK_SIZE_GB}GiB disk image at ${DISK_IMG} inside Minikube (if missing)"
mm_ssh "sudo mkdir -p ${DISK_DIR}"
if ! mm_ssh "test -f ${DISK_IMG}"; then
  mm_ssh "sudo dd if=/dev/zero of=${DISK_IMG} bs=1M count=$((DISK_SIZE_GB * 1024)) status=progress"
else
  log "Disk image already exists: ${DISK_IMG}"
fi

log "Ensure nbd kernel module is available (max_part=8)"
if ! mm_ssh "lsmod | grep -q '^nbd '"; then
  if ! mm_ssh "sudo modprobe nbd max_part=8"; then
    warn "Could not load 'nbd' kernel module inside node. Your Minikube base image may not include it."
    warn "Proceeding, but qemu-nbd attach may fail."
  fi
fi

log "Install qemu-nbd inside Minikube node if available (best-effort)"
# Different Minikube base images use different OSes; apt may not exist.
mm_ssh "if command -v apt >/dev/null 2>&1; then \
           sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-utils; \
         elif command -v dnf >/dev/null 2>&1; then \
           sudo dnf install -y qemu-img qemu-ndb || true; \
         elif command -v apk >/dev/null 2>&1; then \
           sudo apk add --no-cache qemu-img qemu-nbd || true; \
         else \
           echo 'No known package manager found; assuming qemu-nbd is already present' ; \
         fi"

log "Attach ${DISK_IMG} to ${NBD_DEV} with qemu-nbd (if not already attached)"
if mm_ssh "lsblk | grep -q \"^$(basename "${NBD_DEV}" )\""; then
  log "nbd device ${NBD_DEV} already present in lsblk"
else
  mm_ssh "sudo qemu-nbd --format=raw -c ${NBD_DEV} ${DISK_IMG}" || \
    warn "qemu-nbd attach failed; check that qemu-nbd and nbd module are available in your node image"
fi

log "Verify nbd device size"
mm_ssh "lsblk | grep -E \"^$(basename "${NBD_DEV}")\" || true"

# ---------- Clone Rook repo (on host) ----------
WORKDIR="$(pwd)"
CLONE_DIR="${WORKDIR}/rook"
if [[ -d "${CLONE_DIR}/.git" ]]; then
  log "Rook repo already cloned at ${CLONE_DIR}"
else
  log "Cloning Rook from ${ROOK_REPO}"
  git clone "${ROOK_REPO}" "${CLONE_DIR}"
fi

if [[ -n "${ROOK_BRANCH}" ]]; then
  log "Checking out branch/tag ${ROOK_BRANCH}"
  (cd "${CLONE_DIR}" && git fetch --all --tags && git checkout "${ROOK_BRANCH}")
fi

EX_DIR="${CLONE_DIR}/deploy/examples"

# ---------- Deploy Rook-Ceph CRDs & Operator ----------
log "Applying Rook-Ceph CRDs/common/operator"
kubectl apply -f "${EX_DIR}/crds.yaml"
kubectl apply -f "${EX_DIR}/common.yaml"
kubectl apply -f "${EX_DIR}/operator.yaml"

log "Wait for Rook operator to be ready"
kubectl -n "${ROOK_NS}" rollout status deploy/rook-ceph-operator --timeout=300s

# ---------- Create CephCluster ----------
log "Applying CephCluster (cluster.yaml)"
kubectl apply -f "${EX_DIR}/cluster.yaml"

log "Waiting for rook-ceph pods to start (this can take a while)"
kubectl -n "${ROOK_NS}" get pods
# Optional: simple wait loop for mons/mgr/osd to appear
for i in {1..30}; do
  READY=$(kubectl -n "${ROOK_NS}" get cephcluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
  echo "CephCluster phase: ${READY:-unknown}"
  [[ "${READY:-}" == "Ready" ]] && break
  sleep 20
done

# ---------- Toolbox & Ceph status ----------
log "Deploying toolbox"
kubectl apply -f "${EX_DIR}/toolbox.yaml"
kubectl -n "${ROOK_NS}" rollout status deploy/rook-ceph-tools --timeout=300s

log "ceph status from toolbox"
kubectl -n "${ROOK_NS}" exec -it deploy/rook-ceph-tools -- bash -lc 'ceph -s || ceph status || true'

# ---------- CephFS & StorageClass ----------
# filesystem.yaml creates a CephFilesystem (ensure your cluster has enough OSDs/replication settings).
log "Creating CephFS (filesystem.yaml)"
kubectl apply -f "${EX_DIR}/filesystem.yaml"

log "Creating CephFS StorageClass"
kubectl apply -f "${EX_DIR}/csi/cephfs/storageclass.yaml"

log "Done. Next steps:"
echo "- If the nbd attach failed, confirm your Minikube image supports 'nbd' and 'qemu-nbd'."
echo "- Verify Ceph is healthy: kubectl -n ${ROOK_NS} exec -it deploy/rook-ceph-tools -- ceph -s"
echo "- To use CephFS dynamically, create a PVC with storageClassName 'rook-cephfs'."
