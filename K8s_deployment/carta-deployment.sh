#!/usr/bin/env bash
set -euo pipefail

# Deploy carta-backend pods from three manifests.
# Usage:
#   ./deploy_carta.sh                          # uses default namespace 'carta'
#   ./deploy_carta.sh -n otherns               # custom namespace
#   ./deploy_carta.sh --context my-kube-ctx    # custom kubectl context
#
# Expects files in current directory:
#   carta-backend.yaml  carta-b.yaml  carta-c.yaml
# (Optionally also applies common.yaml if present.)

NS="carta"
CTX=""
FILES=("carta-backend.yaml" "carta-b.yaml" "carta-c.yaml")

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    --context) CTX="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

K=kubectl
if [[ -n "${CTX}" ]]; then
  K="kubectl --context ${CTX}"
fi

# --- prereqs ---
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found in PATH"; exit 1; }

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "Required manifest missing: $f"; exit 1; }
done

# If common.yaml exists (Namespace, PVC, etc.), apply it first
if [[ -f "common.yaml" ]]; then
  echo "👉 Applying common.yaml (namespace, PVC, etc.)"
  $K apply -f common.yaml
fi

# Ensure namespace exists
if ! $K get ns "${NS}" >/dev/null 2>&1; then
  echo "👉 Creating namespace ${NS}"
  $K create namespace "${NS}"
else
  echo "✅ Namespace ${NS} exists"
fi

# Helper to apply + wait for a deployment name (auto-detected from file)
apply_and_wait() {
  local file="$1"
  echo "👉 Applying ${file}"
  $K -n "${NS}" apply -f "${file}"

  # Try to detect the deployment name from the manifest
  local name
  name="$($K -n "${NS}" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -E '^carta-backend(-[abc])?$' || true)"

  # If multiple, fallback to extracting from file contents
  if [[ -z "${name}" ]]; then
    name="$(grep -E 'name:\s*carta-backend(-[abc])?' "${file}" | head -1 | awk '{print $2}')"
  fi

  if [[ -z "${name}" ]]; then
    echo "⚠️  Could not detect Deployment name for ${file}. Skipping wait."
    return 0
  fi

  echo "⏳ Waiting for rollout: ${name}"
  $K -n "${NS}" rollout status deploy/"${name}" --timeout=180s
}

# Apply each manifest
for f in "${FILES[@]}"; do
  apply_and_wait "$f"
done

echo "✅ All applies done."

echo
echo "📦 Pods:"
$K -n "${NS}" get pods -l app=carta-backend -o wide

echo
echo "🛰️ Services:"
$K -n "${NS}" get svc -l app=carta-backend

echo
echo "🔎 Quick endpoints (NodePorts if set):"
$K -n "${NS}" get svc -l app=carta-backend -o jsonpath='{range .items[*]}{.metadata.name}{" -> Port "}{.spec.ports[0].port}{" / NodePort "}{.spec.ports[0].nodePort}{"\n"}{end}'
echo
echo "Done."
