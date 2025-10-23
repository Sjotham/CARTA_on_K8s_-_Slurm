#!/usr/bin/env bash
set -euo pipefail

# Config (change if needed)
CARTA_NS="carta"
CARTA_PVC="carta-data"
CARTA_DEPLOY="carta-backend"
SC_NAME="rook-cephfs"          # must already exist (from Rook-Ceph CSI)
ROOK_NS="rook-ceph"            # Rook namespace for CephFilesystem
FS_NAME="myfs"

echo "### Applying CephFilesystem (${FS_NAME}) in namespace ${ROOK_NS}"
# NOTE: If your lab has only 1 OSD, change replicated.size from 2 -> 1.
kubectl apply -f - <<EOF
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: ${FS_NAME}
  namespace: ${ROOK_NS}
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
EOF

echo "### Applying CARTA namespace, PVC, Deployment, and Service"
kubectl apply -f - <<EOF
# 1) Namespace
apiVersion: v1
kind: Namespace
metadata:
  name: ${CARTA_NS}
---
# 2) CephFS PVC (RWX)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${CARTA_PVC}
  namespace: ${CARTA_NS}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ${SC_NAME}
  resources:
    requests:
      storage: 20Gi
  volumeMode: Filesystem
---
# 3) Deployment (PVC mounted at /images)
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
      # Ensure CephFS files are owned/accessible by cartauser (1000)
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch

      # Fix ownership/permissions on /images before the app starts
      initContainers:
        - name: fix-images-perms
          image: busybox:1.36
          command: ["sh","-c","chown -R 1000:1000 /images && chmod -R g+rwX /images"]
          securityContext:
            runAsUser: 0
            runAsGroup: 0
          volumeMounts:
            - name: carta-storage
              mountPath: /images

      containers:
        - name: ${CARTA_DEPLOY}
          image: cartavis/carta:beta
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 3002
          volumeMounts:
            - name: carta-storage
              mountPath: /images          # CARTA scans this by default
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
# 4) NodePort Service
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
      # nodePort: 32002
EOF

echo "### Waiting for PVC to bind and deployment to roll out..."
kubectl -n "${CARTA_NS}" wait --for=condition=Bound pvc/${CARTA_PVC} --timeout=180s
kubectl -n "${CARTA_NS}" rollout status deploy/${CARTA_DEPLOY}

POD="$(kubectl -n "${CARTA_NS}" get pod -l app=${CARTA_DEPLOY} -o jsonpath='{.items[0].metadata.name}')"
echo "### Mount check inside pod:"
kubectl -n "${CARTA_NS}" exec -it "${POD}" -- sh -lc 'mount | grep /images || true; ls -lah /images || true'

echo "### Done. To access locally via port-forward:"
echo "kubectl -n ${CARTA_NS} port-forward pod/${POD} 3002:3002"
echo "Open: http://localhost:3002/?token=<token_from_logs>"
