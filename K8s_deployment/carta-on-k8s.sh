#!/usr/bin/env bash
set -euo pipefail

# If you change names/namespaces, update the YAML files accordingly.
CARTA_NS="carta"
CARTA_DEPLOY="carta-backend"

echo "### Applying manifests"
kubectl apply -f carta-backend.yaml

echo "### Waiting for deployment rollout..."
kubectl -n "${CARTA_NS}" rollout status deploy/${CARTA_DEPLOY}

POD="$(kubectl -n "${CARTA_NS}" get pod -l app=${CARTA_DEPLOY} -o jsonpath='{.items[0].metadata.name}')"
echo "### CARTA pod: ${POD}"

echo "### Checking mount inside pod..."
kubectl -n "${CARTA_NS}" exec -it "${POD}" -- sh -lc 'mount | grep /images || true; ls -lah /images | head'

echo "### CARTA logs (for access token)"
kubectl -n "${CARTA_NS}" logs "${POD}" | tail -n 50

echo "### Port-forward to access CARTA:"
echo "kubectl -n ${CARTA_NS} port-forward pod/${POD} 3002:3002"
echo "Then open http://localhost:3002/?token=<token_from_logs>"
