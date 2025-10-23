#!/usr/bin/env bash
set -euo pipefail

# Paths to your scripts
CEPH_SCRIPT="./deploy-cephfs.sh"
CARTA_SCRIPT="./deploy-carta.sh"

echo "### Starting full deployment ###"

# 1) Deploy Rook-Ceph and CephFS
echo "### Running CephFS setup..."
bash "${k8s-rook-ceph.sh}"

# 2) Deploy CARTA backend
echo "### Running CARTA deployment..."
bash "${carta-on-k8s.sh}"

echo "### All done!"
