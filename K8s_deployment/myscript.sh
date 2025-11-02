#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# setup_carta_env.sh  (corrected + host-nbd flag)
#
# One-stop helper to:
#  - Preflight: fix broken apt sources (kubernetes-xenial) & raise inotify limits
#  - Install host tools (tmux, qemu, git, k9s)
#  - --host-nbd: ONLY do host NBD attach (/dev/nbd0) with a 10GiB file
#  - (Optional) EC2 host: enable NBD and prep a test disk via qemu-nbd
#  - Clean + (re)create a Minikube cluster
#  - Inside the Minikube node: create a 10G file and attach as /dev/nbd0
#  - Install Rook-Ceph (v1.18.4) and verify ceph -s
#
# Usage examples:
#   ./setup_carta_env.sh --all
#   ./setup_carta_env.sh --host-tools
#   ./setup_carta_env.sh --host-nbd
#   ./setup_carta_env.sh --ec2-host-only
#   ./setup_carta_env.sh --minikube
#   ./setup_carta_env.sh --rook
#
# Flags can be combined. --all runs everything in a safe order.
# ------------------------------------------------------------------------------

# ----- Defaults / knobs --------------------------------------------------------
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-cluster-multi}"
MINIKUBE_NODES="${MINIKUBE_NODES:-3}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEM_MB="${MINIKUBE_MEM_MB:-4096}"
K8S_VERSION="${K8S_VERSION:-stable}"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-containerd}"
ROOK_BRANCH="${ROOK_BRANCH:-v1.18.4}"

HOST_TOOLS=false
HOST_NBD_ONLY=false       # <--- NEW: run just the host NBD steps you requested
EC2_HOST_STEPS=false
MINIKUBE_STEPS=false
ROOK_STEPS=false

# ----- Helpers ----------------------------------------------------------------
log() { echo -e "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH"; }

preflight_fix_apt_sources() {
  local changed=0
  if [[ -f /etc/apt/sources.list.d/kubernetes.list ]]; then
    sudo sed -i '/apt\.kubernetes\.io/d' /etc/apt/sources.list.d/kubernetes.list || true
    [[ ! -s /etc/apt/sources.list.d/kubernetes.list ]] && sudo rm -f /etc/apt/sources.list.d/kubernetes.list || true
    changed=1
  fi
  if grep -q 'apt\.kubernetes\.io' /etc/apt/sources.list 2>/dev/null; then
    sudo sed -i '/apt\.kubernetes\.io/d' /etc/apt/sources.list || true
    changed=1
  fi
  (( changed )) && log "Removed deprecated apt.kubernetes.io entries"
}

preflight_raise_sys_limits() {
  if ! grep -q 'fs.inotify.max_user_watches' /etc/sysctl.d/99-inotify.conf 2>/dev/null; then
    echo 'fs.inotify.max_user_watches=524288' | sudo tee /etc/sysctl.d/99-inotify.conf >/dev/null
  fi
  if ! grep -q 'fs.file-max' /etc/sysctl.d/99-file-max.conf 2>/dev/null; then
    echo 'fs.file-max=1000000' | sudo tee /etc/sysctl.d/99-file-max.conf >/dev/null
  fi
  sudo sysctl --system >/dev/null || true
  ulimit -n 1048576 || true
  if [[ ! -f /etc/security/limits.d/99-nofile.conf ]] || ! grep -q 'nofile' /etc/security/limits.d/99-nofile.conf; then
    echo -e '* soft nofile 1048576\n* hard nofile 1048576' | sudo tee /etc/security/limits.d/99-nofile.conf >/dev/null
  fi
}

apt_install() {
  preflight_fix_apt_sources
  preflight_raise_sys_limits
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# --- EXACT host-side NBD steps you asked for (idempotent) ---------------------
host_nbd_setup() {
  log "Host NBD setup: install extras, load module, create/attach /dev/nbd0"

  need_cmd uname
  apt_install "linux-modules-extra-$(uname -r)" nbd-client qemu-utils

  # Load nbd module with partitions
  if ! lsmod | grep -q '^nbd'; then
    sudo modprobe nbd max_part=8
  fi

  # Create/attach backing file
  sudo mkdir -p /mnt/disks
  [[ -f /mnt/disks/mydisk.img ]] || sudo truncate -s 10G /mnt/disks/mydisk.img
  if ! lsblk | grep -q '^nbd0'; then
    sudo qemu-nbd --format=raw --connect=/dev/nbd0 /mnt/disks/mydisk.img
  fi

  # Verify
  ls -l /dev/nbd0 || true
  lsblk | grep nbd0 || true
  log "Host NBD setup complete."
}

# ----- Parse args --------------------------------------------------------------
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--all] [--host-tools] [--host-nbd] [--ec2-host-only] [--minikube] [--rook]"
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)             HOST_TOOLS=true; HOST_NBD_ONLY=true; EC2_HOST_STEPS=true; MINIKUBE_STEPS=true; ROOK_STEPS=true ;;
    --host-tools)      HOST_TOOLS=true ;;
    --host-nbd)        HOST_NBD_ONLY=true ;;   # <--- NEW
    --ec2-host-only)   EC2_HOST_STEPS=true ;;
    --minikube)        MINIKUBE_STEPS=true ;;
    --rook)            ROOK_STEPS=true ;;
    -h|--help)         sed -n '1,160p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
  shift
done

# ----- Step 0: Optional host NBD only -----------------------------------------
if $HOST_NBD_ONLY; then
  host_nbd_setup
fi

# ----- Step 1: Host tools ------------------------------------------------------
if $HOST_TOOLS; then
  log "Installing host tools: tmux, qemu-system, git, k9s"
  need_cmd sudo; need_cmd bash; need_cmd curl; need_cmd sed
  apt_install tmux qemu-system git
  if ! command -v k9s >/dev/null 2>&1; then
    log "Installing k9s with webinstall.dev"
    curl -sS https://webinstall.dev/k9s | bash
  else
    log "k9s already present, skipping"
  fi
  if [[ -f "${HOME}/.config/envman/PATH.env" ]]; then
    grep -q 'envman/PATH.env' "${HOME}/.bashrc" 2>/dev/null || {
      echo 'source ~/.config/envman/PATH.env' >> "${HOME}/.bashrc"
      log "Appended 'source ~/.config/envman/PATH.env' to ~/.bashrc"
    }
    # shellcheck disable=SC1090
    source "${HOME}/.config/envman/PATH.env" || true
  fi
  log "Host tools installation done."
fi

# ----- Step 2: EC2 host-only prep (kernel modules + NBD disk) -----------------
if $EC2_HOST_STEPS; then
  log "Running EC2 host-only steps (Ubuntu/Debian host expected)"
  need_cmd uname; need_cmd lsblk
  apt_install "linux-modules-extra-$(uname -r)" nbd-client qemu-utils
  if ! lsmod | grep -q '^nbd'; then
    log "Loading nbd kernel module"; sudo modprobe nbd max_part=8 || die "Failed to load nbd"
  else
    log "nbd module already loaded"
  fi
  sudo mkdir -p /mnt/disks
  [[ -f /mnt/disks/mydisk.img ]] || { log "Creating sparse 10G file"; sudo truncate -s 10G /mnt/disks/mydisk.img; }
  if lsblk | grep -q '^nbd0'; then
    log "/dev/nbd0 already present"
  else
    log "Connecting /mnt/disks/mydisk.img -> /dev/nbd0 via qemu-nbd"
    sudo qemu-nbd --format=raw --connect=/dev/nbd0 /mnt/disks/mydisk.img || {
      log "qemu-nbd connect failed; trying nbd-client"
      sudo nbd-client -N '' localhost 10809 /dev/nbd0 || die "Failed to attach /dev/nbd0"
    }
  fi
  log "Current NBD devices:"; lsblk | grep nbd || true
  log "EC2 host-only steps complete."
fi

# ----- Step 3: Minikube clean + start -----------------------------------------
if $MINIKUBE_STEPS; then
  log "Setting up Minikube profile '${MINIKUBE_PROFILE}'"
  need_cmd minikube; need_cmd docker; need_cmd kubectl
  log "Deleting Minikube (all profiles) to ensure a clean slate"
  minikube delete --all --purge || true
  log "Starting Minikube '${MINIKUBE_PROFILE}' with ${MINIKUBE_NODES} nodes"
  minikube start \
    -p "${MINIKUBE_PROFILE}" \
    --driver=docker \
    --nodes="${MINIKUBE_NODES}" \
    --cpus="${MINIKUBE_CPUS}" \
    --memory="${MINIKUBE_MEM_MB}" \
    --kubernetes-version="${K8S_VERSION}" \
    --container-runtime="${CONTAINER_RUNTIME}" \
    --force-systemd=true
  log "Creating 10G file and attaching /dev/nbd0 inside minikube node"
  minikube -p "${MINIKUBE_PROFILE}" ssh <<'EOF'
set -euo pipefail
sudo mkdir -p /mnt/disks
[[ -f /mnt/disks/mydisk.img ]] || sudo dd if=/dev/zero of=/mnt/disks/mydisk.img bs=1M count=10240 status=progress
command -v qemu-nbd >/dev/null || { sudo apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-utils; }
lsmod | grep -q '^nbd' || sudo modprobe nbd max_part=8 || true
lsblk | grep -q '^nbd0' || sudo qemu-nbd --format raw -c /dev/nbd0 /mnt/disks/mydisk.img || true
lsblk | grep nbd || true
EOF
  log "Minikube setup complete."
fi

# ----- Step 4: Rook-Ceph install ----------------------------------------------
if $ROOK_STEPS; then
  log "Installing Rook-Ceph (${ROOK_BRANCH})"
  need_cmd git; need_cmd kubectl
  if [[ ! -d rook ]]; then
    git clone --single-branch --branch "${ROOK_BRANCH}" https://github.com/rook/rook.git
  else
    log "Directory 'rook' already exists; skipping clone"
  fi
  pushd rook/deploy/examples >/dev/null
  kubectl create -f crds.yaml -f common.yaml -f csi-operator.yaml -f operator.yaml
  kubectl create -f cluster.yaml
  kubectl create -f toolbox.yaml
  log "Waiting for rook-ceph-tools rollout"
  kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=600s
  log "Running 'ceph -s' inside toolbox"
  kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- bash -lc 'ceph -s || true'
  popd >/dev/null

  # New: apply StorageClass in the same dir as this script
  if [[ -f "${PWD}/storageclass.yaml" ]]; then
    log "Applying storageclass.yaml from current directory"
    kubectl create --dry-run=client -f "${PWD}/storageclass.yaml" -o yaml | kubectl apply -f -
    kubectl get sc
    # kubectl patch sc <your-sc-name> -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  else
    log "storageclass.yaml not found in ${PWD}; skipping"
  fi

  log "Rook-Ceph installation step complete."
