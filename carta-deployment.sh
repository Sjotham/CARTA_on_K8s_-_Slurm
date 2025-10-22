#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG ----------
CARTA_NS="carta"
CARTA_PVC="carta-data"
CARTA_DEPLOY="carta-backend"
SC_NAME="rook-cephfs"
# -----------------------------

echo "### Creating namespace '${CARTA_NS}'"
kubectl create namespace "${CARTA_NS}" --dry-run=client -o yaml | kubectl apply -f -

echo "### Creating CephFS PVC"
cat <<EOF | kubectl apply -f -
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
EOF

echo "### Deploying CARTA backend"
cat <<EOF | kubectl apply -f -
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
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
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
          ports:
            - name: http
              containerPort: 3002
          volumeMounts:
            - name: carta-storage
              mountPath: /images
          readinessProbe:
            tcpSocket: { port: 3002 }
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            tcpSocket: { port: 3002 }
            initialDelaySeconds: 30
            periodSeconds: 10
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
    - port: 3002
      targetPort: 3002
EOF

echo "### Waiting for deployment rollout..."
kubectl -n "${CARTA_NS}" rollout status deploy/${CARTA_DEPLOY}

POD=$(kubectl -n "${CARTA_NS}" get pod -l app=${CARTA_DEPLOY} -o jsonpath='{.items[0].metadata.name}')
echo "### CARTA pod: ${POD}"

echo "### Checking mount inside pod..."
kubectl -n "${CARTA_NS}" exec -it "${POD}" -- sh -lc 'mount | grep /images; ls -lah /images | head'

echo "### CARTA logs (for access token)"
kubectl -n "${CARTA_NS}" logs "${POD}" | tail -n 50

echo "### Port-forward to access CARTA:"
echo "kubectl -n ${CARTA_NS} port-forward pod/${POD} 3002:3002"
echo "Then open http://localhost:3002/?token=<token_from_logs>"
