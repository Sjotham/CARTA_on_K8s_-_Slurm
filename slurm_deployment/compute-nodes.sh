a#!/usr/bin/env bash
set -euo pipefail
#https://www.youtube.com/watch?v=1Yv3QQTv7PI&list=PLWk-zl-RHnbc8PS55ZiJHFtPTQobegyH5
#############################################
# CONFIG – EDIT IF NEEDED                   #
#############################################

# SSH user for passwordless login TO this node or FROM this node
SSH_USER="${SSH_USER:-ubuntu}"

# Controller/login node details
CONTROLLER_IP="${CONTROLLER_IP:-192.168.1.1}"    # HRG-Server IP
CONTROLLER_HOST="${CONTROLLER_HOST:-HRG-Server}" # hostname for controller

# This compute node (example from your notes)
THIS_IP="${THIS_IP:-192.168.7.2}"
THIS_HOST="${THIS_HOST:-HRG-01}"

# NFS mount point
NFS_MOUNT="${NFS_MOUNT:-/nfs}"

# UID for munge & slurm users (must match controller)
MUNGE_UID="${MUNGE_UID:-1001}"
SLURM_UID="${SLURM_UID:-1002}"

#############################################
echo "=== 1) SSH installation and basic checks ==="

sudo apt update -y
sudo apt install -y openssh-server

sudo systemctl enable --now ssh

# Allow SSH via UFW if present
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow ssh || true
fi

echo "=== Checking sshd processes ==="
ps -A | grep -E 'sshd' || echo "WARNING: sshd not visible in ps output"
sudo ss -lnp | grep -E 'sshd' || echo "WARNING: sshd not visible in ss output" || true

echo "=== Testing SSH to localhost ==="
ssh -o StrictHostKeyChecking=no -v localhost true || echo "NOTE: ssh localhost returned non-zero; check verbose output above."

#############################################
echo "=== 2) Enable passwordless SSH (key generation + copy) ==="

# Generate key if not present
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  ssh-keygen -t rsa -N "" -f "$HOME/.ssh/id_rsa"
fi

# Example: copy key to controller (you can change the target)
echo "Copying SSH key to controller ${SSH_USER}@${CONTROLLER_IP} (you may be asked for password once)..."
ssh-copy-id "${SSH_USER}@${CONTROLLER_IP}" || echo "ssh-copy-id failed; adjust SSH_USER/CONTROLLER_IP if needed."

#############################################
echo "=== 3) Update /etc/hosts with controller and this node ==="

# Add controller mapping
if ! grep -q "${CONTROLLER_IP} ${CONTROLLER_HOST}" /etc/hosts; then
  echo "${CONTROLLER_IP} ${CONTROLLER_HOST}" | sudo tee -a /etc/hosts
fi

# Add this node mapping
if ! grep -q "${THIS_IP} ${THIS_HOST}" /etc/hosts; then
  echo "${THIS_IP} ${THIS_HOST}" | sudo tee -a /etc/hosts
fi

#############################################
echo "=== 4) NFS client setup on compute node ==="

sudo apt-get install -y nfs-common

sudo mkdir -p "${NFS_MOUNT}"

# Add to /etc/fstab if not already present
FSTAB_LINE="${CONTROLLER_HOST}:${NFS_MOUNT} ${NFS_MOUNT} nfs defaults 0 0"
if ! grep -q "${CONTROLLER_HOST}:${NFS_MOUNT}" /etc/fstab; then
  echo "${FSTAB_LINE}" | sudo tee -a /etc/fstab
fi

sudo systemctl daemon-reload
sudo mount -a

ls -ld "${NFS_MOUNT}" || echo "WARNING: NFS mount may have failed; check /etc/fstab and network."

#############################################
echo "=== 5) Create munge and slurm users/groups on compute node ==="

# munge group/user
if ! getent group munge >/dev/null 2>&1; then
  sudo groupadd -g "${MUNGE_UID}" munge
fi
if ! id -u munge >/dev/null 2>&1; then
  sudo useradd -m -c "MUNGE Uid 'N' Gid Emporium" \
    -d /var/lib/munge -u "${MUNGE_UID}" -g munge -s /sbin/nologin munge
fi

# slurm group/user
if ! getent group slurm >/dev/null 2>&1; then
  sudo groupadd -g "${SLURM_UID}" slurm
fi
if ! id -u slurm >/dev/null 2>&1; then
  sudo useradd -m -c "SLURM workload manager" \
    -d /var/lib/slurm -u "${SLURM_UID}" -g slurm -s /bin/bash slurm
fi

sudo apt-get install -y munge

sudo mkdir -p /etc/munge /var/log/munge /var/lib/munge /run/munge
sudo chown -R munge: /etc/munge/ /var/log/munge/ /var/lib/munge/ /run/munge/
sudo chmod 0700 /etc/munge/ /var/log/munge/ /var/lib/munge/ /run/munge/

echo "=== 6) Copy munge.key from NFS to /etc/munge ==="
# Assumes controller put munge.key into /nfs/slurm/munge.key
if [ -f "${NFS_MOUNT}/slurm/munge.key" ]; then
  sudo cp "${NFS_MOUNT}/slurm/munge.key" /etc/munge/munge.key
else
  echo "ERROR: ${NFS_MOUNT}/slurm/munge.key not found – make sure controller exported it."
fi

sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

sudo systemctl enable munge
sudo systemctl restart munge

#############################################
echo "=== 7) Install Slurm worker (slurm-wlm) ==="

sudo apt-get install -y slurm-wlm

#############################################
echo "=== 8) Copy slurm.conf and slurmdbd.conf from NFS to /etc/slurm ==="

sudo mkdir -p /etc/slurm

if [ -f "${NFS_MOUNT}/slurm/slurm.conf" ]; then
  sudo cp "${NFS_MOUNT}/slurm/slurm.conf" /etc/slurm/slurm.conf
else
  echo "WARNING: ${NFS_MOUNT}/slurm/slurm.conf not found"
fi

if [ -f "${NFS_MOUNT}/slurm/slurmdbd.conf" ]; then
  sudo cp "${NFS_MOUNT}/slurm/slurmdbd.conf" /etc/slurm/slurmdbd.conf
else
  echo "WARNING: ${NFS_MOUNT}/slurm/slurmdbd.conf not found"
fi

#############################################
echo "=== 9) Prepare slurmd directories and permissions ==="

sudo mkdir -p /var/spool/slurmd
sudo chown slurm: /var/spool/slurmd
sudo chmod 755 /var/spool/slurmd

sudo mkdir -p /var/log/slurm
sudo touch /var/log/slurm/slurmd.log
sudo chown -R slurm:slurm /var/log/slurm/slurmd.log
sudo chmod 755 /var/log/slurm

sudo mkdir -p /run/slurm
sudo touch /run/slurm/slurmd.pid
sudo chown slurm:slurm /run/slurm
sudo chmod -R 770 /run/slurm

#############################################
echo "=== 10) Cgroup config and slurmd startup ==="

# Append cgroup mountpoint to Slurm cgroup.conf
sudo mkdir -p /etc/slurm
sudo bash -c "echo 'CgroupMountpoint=/sys/fs/cgroup' >> /etc/slurm/cgroup.conf"

# Optional: show hardware config
if command -v slurmd >/dev/null 2>&1; then
  slurmd -C || true
fi

sudo systemctl enable slurmd.service
sudo systemctl start slurmd.service
sudo systemctl status slurmd.service --no-pager || true

echo
echo "=== Compute node setup complete ==="
echo "On the controller node, you can now check connectivity with:"
echo "  scontrol ping"
