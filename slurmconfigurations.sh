#!/bin/bash

set -e  # Exit on any error

##############################
### Login Node Setup (vm1) ###
##############################
if [[ "$HOSTNAME" == "vm1" ]]; then
  echo "=== Installing SLURM on Login Node ($HOSTNAME) ==="

  export MUNGEUSER=1001
  export SLURMUSER=1002

  echo "=== Creating users ==="
  sudo groupadd -g $MUNGEUSER munge || true
  sudo useradd -m -c "MUNGE Uid 'N' Gid Emporium" -d /var/lib/munge -u $MUNGEUSER -g munge -s /sbin/nologin munge || true
  sudo groupadd -g $SLURMUSER slurm || true
  sudo useradd -m -c "SLURM workload manager" -d /var/lib/slurm -u $SLURMUSER -g slurm -s /bin/bash slurm || true

  echo "=== Installing packages ==="
  sudo apt-get update
  sudo apt-get install -y munge mariadb-server slurmdbd slurm-wlm

  echo "=== Setting MUNGE permissions ==="
  sudo chown -R munge: /etc/munge/ /var/log/munge/ /var/lib/munge/ /run/munge/
  sudo chmod 0700 /etc/munge/ /var/log/munge/ /var/lib/munge/ /run/munge/
# Copying folder of file system
  sudo scp /etc/munge/munge.key /data/slurm/
  sudo systemctl enable munge
  sudo systemctl start munge

  echo "=== Configuring SLURM Accounting DB ==="
  sudo mysql -e "CREATE DATABASE slurm_acct_db;"
  sudo mysql -e "GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost' IDENTIFIED BY 'hashmi12' WITH GRANT OPTION;"

  echo "=== Creating SLURM config files ==="
  sudo mkdir -p /etc/slurm-llnl

  sudo tee /etc/slurm-llnl/slurmdbd.conf > /dev/null <<EOF
AuthType=auth/munge
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
DebugLevel=4
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurm/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageLoc=slurm_acct_db
StoragePass=hashmi12
StorageUser=slurm
PurgeEventAfter=12months
PurgeJobAfter=12months
PurgeResvAfter=2months
PurgeStepAfter=2months
PurgeSuspendAfter=1month
PurgeTXNAfter=12months
PurgeUsageAfter=12months
EOF

  sudo tee /etc/slurm-llnl/slurm.conf > /dev/null <<EOF
ClusterName=cluster
ControlMachine=vm1
SlurmUser=slurm
SlurmctldPort=6817
SlurmdPort=6818
AuthType=auth/munge
StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SwitchType=switch/none
MpiDefault=none
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
ProctrackType=proctrack/pgid
CacheGroups=0
ReturnToService=1
SchedulerType=sched/backfill
SlurmctldTimeout=300
SlurmdTimeout=300
MinJobAge=300
KillWait=30
Waittime=0
FastSchedule=1
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStorageUser=slurm
AccountingStoragePass=hashmi12
JobCompType=jobcomp/none
NodeName=vm1 CPUs=2 State=UNKNOWN
NodeName=vm2 CPUs=2 State=UNKNOWN
NodeName=vm3 CPUs=2 State=UNKNOWN
PartitionName=debug Nodes=ALL Default=YES MaxTime=INFINITE State=UP
EOF

  sudo chown slurm:slurm /etc/slurm-llnl/slurmdbd.conf
  sudo chmod 600 /etc/slurm-llnl/slurmdbd.conf

  echo "=== Creating runtime and log directories ==="
  sudo mkdir -p /var/spool/slurmctld /var/log/slurm
  sudo chown slurm:slurm /var/spool/slurmctld
  sudo chmod 755 /var/spool/slurmctld
  sudo touch /var/log/slurm/slurmctld.log
  sudo touch /var/log/slurm/slurm_jobacct.log /var/log/slurm/slurm_jobcomp.log
  sudo chown -R slurm:slurm /var/log/slurm/
  sudo chmod 755 /var/log/slurm/

  echo "CgroupMountpoint=/sys/fs/cgroup" | sudo tee /etc/slurm-llnl/cgroup.conf

  echo "=== Opening firewall ports ==="
  sudo ufw allow 6817
  sudo ufw allow 6818
  sudo ufw allow 6819

  echo "=== Starting SLURM services ==="
  sudo systemctl daemon-reload
  sudo systemctl enable slurmdbd
  sudo systemctl start slurmdbd
  sudo systemctl enable slurmctld
  sudo systemctl start slurmctld
  sudo systemctl status slurmdbd
  sudo systemctl status slurmctld

  echo "=== Login Node setup complete ==="
fi

#################################
### Compute Node Setup (vm2+) ###
#################################
if [[ "$HOSTNAME" != "vm1" ]]; then
  echo "=== Installing SLURM on Compute Node ($HOSTNAME) ==="

  export MUNGEUSER=1001
  export SLURMUSER=1002

  echo "=== Creating users ==="
  sudo groupadd -g $MUNGEUSER munge || true
  sudo useradd -m -c "MUNGE Uid 'N' Gid Emporium" -d /var/lib/munge -u $MUNGEUSER -g munge -s /sbin/nologin munge || true
  sudo groupadd -g $SLURMUSER slurm || true
  sudo useradd -m -c "SLURM workload manager" -d /var/lib/slurm -u $SLURMUSER -g slurm -s /bin/bash slurm || true

  echo "=== Installing packages ==="
  sudo apt-get update
  sudo apt-get install -y munge slurm-wlm

  echo "=== Copying munge key from NFS ==="
  sudo scp /nfs/slurm/munge.key /etc/munge/
  sudo chown munge:munge /etc/munge/munge.key
  sudo chmod 400 /etc/munge/munge.key
  sudo systemctl enable munge
  sudo systemctl start munge

  echo "=== Copying SLURM config files ==="
  sudo mkdir -p /etc/slurm
  sudo scp /nfs/slurm/slurm.conf /etc/slurm/
  sudo scp /data/slurm/slurmdbd.conf /etc/slurm/

  echo "=== Setting up slurmd runtime ==="
  sudo mkdir -p /var/spool/slurmd /var/log/slurm /run/slurm
  sudo chown slurm: /var/spool/slurmd
  sudo chmod 755 /var/spool/slurmd
  sudo touch /var/log/slurm/slurmd.log
  sudo chown -R slurm:slurm /var/log/slurm/
  sudo chmod 755 /var/log/slurm
  sudo touch /run/slurm/slurmd.pid
  sudo chown slurm:slurm /run/slurm
  sudo chmod -R 770 /run/slurm

  echo "CgroupMountpoint=/sys/fs/cgroup" | sudo tee /etc/slurm/cgroup.conf

  echo "=== Starting slurmd service ==="
  sudo systemctl daemon-reexec
  sudo systemctl enable slurmd
  sudo systemctl start slurmd
  sudo systemctl status slurmd

  echo "=== Verifying SLURM connectivity ==="
  scontrol ping || true

  echo "=== Compute Node setup complete. Reboot recommended ==="
fi
