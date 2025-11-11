#!/usr/bin/env bash
set -euo pipefail

#############################################
# CONFIG SECTION – EDIT FOR YOUR CLUSTER    #
#############################################

# SSH user for passwordless SSH
SSH_USER="${SSH_USER:-ubuntu}"

# Login (NFS/Slurm controller) node
LOGIN_IP="${LOGIN_IP:-192.168.1.1}"
LOGIN_HOSTNAME="${LOGIN_HOSTNAME:-VM1}"

# Example compute node (for ssh-copy-id convenience)
COMPUTE1_IP="${COMPUTE1_IP:-192.168.7.2}"
COMPUTE1_HOSTNAME="${COMPUTE1_HOSTNAME:-VM2}"

# NFS export directory on login node
NFS_EXPORT_DIR="${NFS_EXPORT_DIR:-/nfs}"

# Munge & Slurm users (UIDs can be changed if needed)
MUNGE_UID="${MUNGE_UID:-1001}"
SLURM_UID="${SLURM_UID:-1002}"

# Slurm DB settings
SLURM_DB_NAME="${SLURM_DB_NAME:-slurm_acct_db}"
SLURM_DB_USER="${SLURM_DB_USER:-slurm}"
SLURM_DB_PASS="${SLURM_DB_PASS:-hashmi12}"
SLURM_ETC_DIR="${SLURM_ETC_DIR:-/etc/slurm-llnl}"

#############################################
# COMMON: SSH SETUP ON ALL NODES            #
#############################################

setup_ssh_common() {
  echo "=== [COMMON] Install and configure SSH ==="

  sudo apt update -y
  sudo apt install -y openssh-server

  # Ensure ssh is enabled and started
  sudo systemctl enable --now ssh

  # Allow SSH in firewall if ufw exists
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow ssh || true
  fi

  echo "=== [COMMON] Check sshd processes ==="
  ps -A | grep -E 'sshd' || echo "WARNING: sshd not found in ps output"
  sudo ss -lnp | grep -E 'sshd' || echo "WARNING: sshd not found in ss output" || true

  echo "=== [COMMON] Test SSH to localhost (verbose) ==="
  ssh -o StrictHostKeyChecking=no -v localhost true || echo "NOTE: ssh localhost test returned non-zero; check output above."
}

setup_ssh_passwordless() {
  echo "=== [COMMON] Configure SSH key for passwordless access ==="

  # Generate SSH key if not present
  if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    ssh-keygen -t rsa -N "" -f "$HOME/.ssh/id_rsa"
  fi

  echo "Copying SSH key to example compute node: ${SSH_USER}@${COMPUTE1_IP}"
  echo "You may be prompted for the password once."
  ssh-copy-id "${SSH_USER}@${COMPUTE1_IP}" || echo "ssh-copy-id failed; adjust SSH_USER/COMPUTE1_IP if needed."

  echo
  echo "=== [COMMON] /etc/hosts entries (manual review still recommended) ==="
  echo "Adding basic host mappings if missing..."
  sudo grep -q "${LOGIN_IP} ${LOGIN_HOSTNAME}" /etc/hosts || \
    echo "${LOGIN_IP} ${LOGIN_HOSTNAME}" | sudo tee -a /etc/hosts
  sudo grep -q "${COMPUTE1_IP} ${COMPUTE1_HOSTNAME}" /etc/hosts || \
    echo "${COMPUTE1_IP} ${COMPUTE1_HOSTNAME}" | sudo tee -a /etc/hosts
}

#############################################
# LOGIN NODE: NFS SERVER                    #
#############################################

setup_nfs_server() {
  echo "=== [LOGIN] Setting up NFS server ==="

  # On Ubuntu the package is nfs-kernel-server (nfs-server is often a transitional name)
  sudo apt-get install -y nfs-kernel-server

  sudo mkdir -p "${NFS_EXPORT_DIR}"
  # Example owner 'hashmi' from your notes; adjust as needed
  if id -u hashmi >/dev/null 2>&1; then
    sudo chown hashmi:hashmi "${NFS_EXPORT_DIR}"
  else
    sudo chown "${USER}:${USER}" "${NFS_EXPORT_DIR}"
  fi

  echo "=== [LOGIN] Configure /etc/exports ==="
  # Add export line if it doesn't exist
  EXPORT_LINE="${NFS_EXPORT_DIR} *(rw,sync)"
  if ! grep -q "^${NFS_EXPORT_DIR} " /etc/exports; then
    echo "${EXPORT_LINE}" | sudo tee -a /etc/exports
  fi

  sudo exportfs -ra
  sudo systemctl restart nfs-kernel-server

  ls -ld "${NFS_EXPORT_DIR}"
}

#############################################
# COMPUTE NODES: NFS CLIENT                 #
#############################################

setup_nfs_client() {
  echo "=== [COMPUTE] Setting up NFS client ==="

  sudo apt-get update -y
  # On Ubuntu typically nfs-common; 'nfs-client' is sometimes an alias
  sudo apt-get install -y nfs-common

  sudo mkdir -p "${NFS_EXPORT_DIR}"

  # Use LOGIN_HOSTNAME (e.g., VM1) as the NFS server host
  FSTAB_LINE="${LOGIN_HOSTNAME}:${NFS_EXPORT_DIR} ${NFS_EXPORT_DIR} nfs defaults 0 0"

  if ! grep -q "${LOGIN_HOSTNAME}:${NFS_EXPORT_DIR}" /etc/fstab; then
    echo "${FSTAB_LINE}" | sudo tee -a /etc/fstab
  fi

  sudo systemctl daemon-reload
  sudo mount -a

  ls -ld "${NFS_EXPORT_DIR}" || echo "WARNING: NFS mount may have failed; check /etc/fstab and network reachability."
}

#############################################
# LOGIN NODE: SLURM CONTROLLER SETUP        #
#############################################

setup_slurm_login() {
  echo "=== [LOGIN] Installing Slurm controller stack (MUNGE + MariaDB + slurmdbd + slurm-wlm) ==="

  # Create munge user/group
  if ! getent group munge >/dev/null 2>&1; then
    sudo groupadd -g "${MUNGE_UID}" munge
  fi
  if ! id -u munge >/dev/null 2>&1; then
    sudo useradd -m -c "MUNGE Uid 'N' Gid Emporium" \
      -d /var/lib/munge -u "${MUNGE_UID}" -g munge -s /sbin/nologin munge
  fi

  # Create slurm user/group
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

  # Generate munge.key if not present
  if [ ! -f /etc/munge/munge.key ]; then
    sudo /usr/sbin/mungekey
  fi

  # Copy munge.key into NFS share so compute nodes can retrieve it
  sudo mkdir -p "${NFS_EXPORT_DIR}/slurm"
  sudo cp -f /etc/munge/munge.key "${NFS_EXPORT_DIR}/slurm/"

  sudo systemctl enable munge
  sudo systemctl restart munge

  echo "=== [LOGIN] Install Slurm and accounting components ==="
  sudo apt-get install -y mariadb-server
  sudo apt-get install -y slurmdbd slurm-wlm

  echo "=== [LOGIN] Configure Slurm accounting database ==="
  sudo mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${SLURM_DB_NAME};
CREATE USER IF NOT EXISTS '${SLURM_DB_USER}'@'localhost' IDENTIFIED BY '${SLURM_DB_PASS}';
GRANT ALL ON ${SLURM_DB_NAME}.* TO '${SLURM_DB_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

  echo "=== [LOGIN] Create slurmdbd.conf ==="
  sudo mkdir -p "${SLURM_ETC_DIR}"
  sudo bash -c "cat > ${SLURM_ETC_DIR}/slurmdbd.conf" <<EOF
AuthType=auth/munge
DbdAddr=localhost
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
DebugLevel=4
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurm/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageLoc=${SLURM_DB_NAME}
StoragePass=${SLURM_DB_PASS}
StorageUser=${SLURM_DB_USER}
PurgeEventAfter=12months
PurgeJobAfter=12months
PurgeResvAfter=2months
PurgeStepAfter=2months
PurgeSuspendAfter=1month
PurgeTXNAfter=12months
PurgeUsageAfter=12months
EOF

  sudo chown slurm:slurm "${SLURM_ETC_DIR}/slurmdbd.conf"
  sudo chmod 600 "${SLURM_ETC_DIR}/slurmdbd.conf"

  echo "=== [LOGIN] Prepare Slurm state/log directories ==="
  sudo mkdir -p /var/spool/slurmctld
  sudo chown slurm:slurm /var/spool/slurmctld
  sudo chmod 755 /var/spool/slurmctld

  sudo mkdir -p /var/log/slurm
  sudo touch /var/log/slurm/slurmctld.log \
             /var/log/slurm/slurm_jobacct.log \
             /var/log/slurm/slurm_jobcomp.log
  sudo chown -R slurm:slurm /var/log/slurm
  sudo chmod 755 /var/log/slurm

  echo "=== [LOGIN] Open Slurm ports in firewall (6817, 6818, 6819) ==="
  if command -v ufw >/dev/null 2>&1; then
    sudo ufw allow 6817 || true
    sudo ufw allow 6818 || true
    sudo ufw allow 6819 || true
  fi

  echo "=== [LOGIN] Create minimal slurm.conf if missing (you must edit later) ==="
  if [ ! -f "${SLURM_ETC_DIR}/slurm.conf" ]; then
    sudo bash -c "cat > ${SLURM_ETC_DIR}/slurm.conf" <<EOF
# Generate a full config from: https://slurm.schedmd.com/configurator.html
ClusterName=cluster
SlurmctldHost=$(hostname -s)
SlurmUser=slurm
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
AuthType=auth/munge
ProctrackType=proctrack/cgroup
ReturnToService=1
SchedulerType=sched/backfill
SelectType=select/cons_tres
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# TODO: Replace with real nodes/partitions
NodeName=login CPUs=2 RealMemory=2048 State=UNKNOWN
PartitionName=debug Nodes=login Default=YES MaxTime=INFINITE State=UP
EOF
  else
    echo "${SLURM_ETC_DIR}/slurm.conf already exists; not overwriting."
  fi

  echo "=== [LOGIN] Add CgroupMountpoint to cgroup.conf ==="
  sudo bash -c "echo 'CgroupMountpoint=/sys/fs/cgroup' >> ${SLURM_ETC_DIR}/cgroup.conf"

  echo
  echo "NOTE: If needed, manually review systemd service unit files:"
  echo "  /usr/lib/systemd/system/slurmctld.service"
  echo "  /usr/lib/systemd/system/slurmdbd.service"
  echo "  /usr/lib/systemd/system/slurmd.service"
  echo

  echo "=== [LOGIN] Start Slurm services ==="
  sudo systemctl daemon-reload
  sudo systemctl enable slurmdbd
  sudo systemctl start slurmdbd
  sudo systemctl enable slurmctld
  sudo systemctl start slurmctld

  sudo systemctl status slurmdbd --no-pager || true
  sudo systemctl status slurmctld --no-pager || true
}

#############################################
# MAIN ENTRYPOINT                           #
#############################################

ROLE="${1:-login}"  # "login" or "compute"

case "${ROLE}" in
  login)
    echo "=== Running cluster setup in LOGIN mode ==="
    setup_ssh_common
    setup_ssh_passwordless
    setup_nfs_server
    setup_slurm_login
    ;;
  compute)
    echo "=== Running cluster setup in COMPUTE mode ==="
    setup_ssh_common
    setup_ssh_passwordless
    setup_nfs_client
    echo
    echo "Now copy /etc/munge/munge.key from NFS share and set up slurmd on this node."
    ;;
  *)
    echo "Usage: $0 {login|compute}"
    exit 1
    ;;
esac

echo "=== DONE (${ROLE} mode) ==="
