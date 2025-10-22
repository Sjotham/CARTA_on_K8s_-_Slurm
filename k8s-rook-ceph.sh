#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG ----------
PROFILE="cluster-multi"
NODES=3
CPUS=4
MEMORY=4096
K8S_VERSION="stable"
ROOK_BRANCH="v1.14.9"
DISK_SIZE_GB=10
DEVICE_NAME="/dev/nbd0"
ROOK_NS="rook-ceph"
CEPH_IMAGE="quay.io/ceph/ceph:v18"
FS_NAME="myfs"
SC_NAME="rook-cephfs"
# -----------------------------

echo "### Cleaning old Minikube cluster"
minikube delete -p "${PROFILE}" --purge || true

echo "### Starting Minikube cluster"
minikube start -p "${PROFILE}" \
  --driver=docker \
  --nodes="${NODES}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --kubernetes-version="${K8S_VERSION}"

# Ensure kubectl exists
if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing kubectl..."
  curl -L -o kubectl "https://dl.k8s.io/release/v1.29.6/bin/linux/amd64/kubectl"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
fi

kubectl get nodes -o wide

# Pick a worker node
TARGET_NODE="$(kubectl get nodes -o jsonpath='{.items[?(!@.metadata.labels."node-role.kubernetes.io/control-plane")].metadata.name}' | awk '{print $1}')"
[[ -z "${TARGET_NODE}" ]] && TARGET_NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
echo "### Using node: ${TARGET_NODE}"

echo "### Preparing Ceph OSD image"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo mkdir -p /mnt/disks"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo dd if=/dev/zero of=/mnt/disks/mydisk.img bs=1M count=$((DISK_SIZE_GB*1024)) status=progress"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo apt-get update -y && sudo apt-get install -y qemu-utils || true"

echo "### Attaching device"
if minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo modprobe nbd max_part=8 && sudo qemu-nbd --format raw -c ${DEVICE_NAME} /mnt/disks/mydisk.img"; then
  DEVICE_NAME="/dev/nbd0"
else
  minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo losetup -fP /mnt/disks/mydisk.img"
  DEVICE_NAME="$(minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "losetup -a | head -n1 | cut -d: -f1" | tr -d '\r')"
fi
echo "### Using device: ${DEVICE_NAME}"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "lsblk | egrep 'nbd|loop' || true"

# ---- Deploy Rook-Ceph ----
if [[ ! -d rook ]]; then
  git clone --depth 1 --branch "${ROOK_BRANCH}" https://github.com/rook/rook.git
fi

cd rook/deploy/examples
kubectl apply -f crds.yaml -f common.yaml -f operator.yaml -f csi-operator.yaml
kubectl -n "${ROOK_NS}" rollout status deploy/rook-ceph-operator

# Create CephCluster
cat > cluster-test.yaml <<EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: my-cluster
  namespace: ${ROOK_NS}
spec:
  cephVersion:
    image: ${CEPH_IMAGE}
  dataDirHostPath: /var/lib/rook
  mon:
    count: 1
  dashboard:
    enabled: true
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
      - name: ${TARGET_NODE}
        devices:
          - name: ${DEVICE_NAME}
    allowDeviceClassUpdate: true
    allowOsdCrushWeightUpdate: false
EOF

kubectl apply -f cluster-test.yaml
echo "### Waiting for Ceph pods..."
sleep 30
kubectl -n "${ROOK_NS}" get pods

# Create CephFS and StorageClass
cat <<EOF | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: ${FS_NAME}
  namespace: ${ROOK_NS}
spec:
  metadataPool:
    replicated: { size: 1 }
  dataPools:
    - name: replicated
      replicated: { size: 1 }
  preserveFilesystemOnDelete: true
  metadataServer:
    activeCount: 1
    activeStandby: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NAME}
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: ${ROOK_NS}
  fsName: ${FS_NAME}
  pool: ${FS_NAME}-replicated
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: ${ROOK_NS}
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: ${ROOK_NS}
reclaimPolicy: Delete
EOF

echo "✅ CephFS StorageClass created: ${SC_NAME}"
kubectl get sc

