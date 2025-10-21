#!/usr/bin/env bash
set -euo pipefail

# -------- CONFIG --------
PROFILE="cluster-multi"
NODES=3
CPUS=4
MEMORY=4096
K8S_VERSION="stable"
ROOK_BRANCH="v1.14.9"
DISK_SIZE_GB=10
TARGET_NODE=""
DEVICE_NAME="/dev/nbd0"
CARTA_NS="carta"
CARTA_PVC="carta-data"
CARTA_DEPLOY="carta-backend"
CARTA_SC="rook-cephfs"
# -------------------------

echo "## Cleaning old Minikube cluster"
minikube delete --purge || true

echo "## Starting Minikube (${PROFILE})"
minikube start \
  -p "${PROFILE}" \
  --driver=docker \
  --nodes="${NODES}" \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --kubernetes-version="${K8S_VERSION}" \
  --container-runtime=containerd

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing kubectl..."
  curl -L -o kubectl "https://dl.k8s.io/release/v1.29.6/bin/linux/amd64/kubectl"
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
fi

kubectl get nodes -o wide

# Auto-pick worker node
if [[ -z "${TARGET_NODE}" ]]; then
  TARGET_NODE="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels["node-role.kubernetes.io/control-plane"]}{"\n"}{end}' \
    | awk '$2=="" {print $1}' | head -n1)"
  [[ -z "${TARGET_NODE}" ]] && TARGET_NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
fi
echo "## Using node: ${TARGET_NODE}"

echo "## Preparing Ceph OSD disk image on ${TARGET_NODE}"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo mkdir -p /mnt/disks"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo dd if=/dev/zero of=/mnt/disks/mydisk.img bs=1M count=$((DISK_SIZE_GB*1024)) status=progress"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo apt-get update -y && sudo apt-get install -y qemu-utils || true"

echo "## Attaching image to ${DEVICE_NAME} (or loop if nbd unavailable)"
if minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo modprobe nbd max_part=8 && sudo qemu-nbd --format raw -c ${DEVICE_NAME} /mnt/disks/mydisk.img"; then
  DEVICE_NAME="/dev/nbd0"
else
  minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "sudo losetup -fP /mnt/disks/mydisk.img"
  DEVICE_NAME="$(minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "losetup -a | head -n1 | cut -d: -f1" | tr -d '\r')"
fi
echo "## Using device: ${DEVICE_NAME}"
minikube -p "${PROFILE}" ssh -n "${TARGET_NODE}" -- "lsblk | egrep 'nbd|loop' || true"

# ----------------- ROOK CEPH -----------------
if [[ ! -d rook ]]; then
  git clone --depth 1 --branch "${ROOK_BRANCH}" https://github.com/rook/rook.git
fi
cd rook/deploy/examples/

kubectl apply -f crds.yaml -f common.yaml -f operator.yaml -f csi-operator.yaml
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator

echo "## Patch cluster-test.yaml for node ${TARGET_NODE}"
cp -n cluster-test.yaml cluster-test.yaml.bak || true
cat > cluster-test.yaml <<EOF
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: my-cluster
  namespace: rook-ceph
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v18
  dataDirHostPath: /var/lib/rook
  mon:
    count: 1
    allowMultiplePerNode: false
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

echo "## Wait a bit for Ceph pods"
sleep 30
kubectl -n rook-ceph get pods

# --------- Add filesystem.yaml and storage.yaml ---------
echo "## Creating CephFS filesystem (myfs) and StorageClass (rook-cephfs)"
cat <<EOF | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: myfs
  namespace: rook-ceph
spec:
  metadataPool:
    replicated:
      size: 2
  dataPools:
    - name: replicated
      replicated:
        size: 2
  preserveFilesystemOnDelete: true
  metadataServer:
    activeCount: 1
    activeStandby: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rook-cephfs
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: myfs
  pool: myfs-replicated
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-publish-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-publish-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
EOF

kubectl get sc

# ----------------- CARTA -----------------
echo "## Deploying CARTA backend with CephFS PVC"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${CARTA_NS}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CARTA_PVC}
  namespace: ${CARTA_NS}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ${CARTA_SC}
  resources:
    requests:
      storage: 20Gi
  volumeMode: Filesystem
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${CARTA_DEPLOY}
  namespace: ${CARTA_NS}
  labels:
    app: ${CARTA_DEPLOY}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ${CARTA_DEPLOY}
  template:
    metadata:
      labels:
        app: ${CARTA_DEPLOY}
    spec:
      securityContext:
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: ${CARTA_DEPLOY}
          image: cartavis/carta:beta
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3002
          volumeMounts:
            - name: carta-storage
              mountPath: /images
          startupProbe:
            tcpSocket: { port: 3002 }
            failureThreshold: 30
            periodSeconds: 2
          readinessProbe:
            tcpSocket: { port: 3002 }
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            tcpSocket: { port: 3002 }
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: carta-storage
          persistentVolumeClaim:
            claimName: ${CARTA_PVC}
---
apiVersion: v1
kind: Service
metadata:
  name: ${CARTA_DEPLOY}
  namespace: ${CARTA_NS}
spec:
  type: NodePort
  selector:
    app: ${CARTA_DEPLOY}
  ports:
    - name: tcp
      port: 3002
      targetPort: 3002
EOF

echo "## Wait for PVC and CARTA rollout"
kubectl -n "${CARTA_NS}" wait --for=condition=Bound pvc/${CARTA_PVC} --timeout=180s
kubectl -n "${CARTA_NS}" rollout status deploy/${CARTA_DEPLOY}

POD=$(kubectl -n "${CARTA_NS}" get pod -l app=${CARTA_DEPLOY} -o jsonpath='{.items[0].metadata.name}')
echo "## Mount check inside CARTA pod:"
kubectl -n "${CARTA_NS}" exec -it "${POD}" -- sh -lc 'mount | grep /images; ls -lah /images'

echo "## CARTA logs (look for token)"
kubectl -n "${CARTA_NS}" logs "${POD}" | tail -n 50

echo "## Access with:"
echo "kubectl -n ${CARTA_NS} port-forward pod/${POD} 3002:3002"
echo "Then open: http://localhost:3002/?token=<token_from_logs>"
