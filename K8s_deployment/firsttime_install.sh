#!/bin/bash
set -euo pipefail

# =====================================================================
# Docker Engine + Minikube + kubectl (Ubuntu 22.04/24.04)
# - Removes old Docker bits
# - Installs Docker CE from the official repo
# - Installs Minikube
# - Installs kubectl from pkgs.k8s.io (replaces deprecated apt.kubernetes.io)
# - Raises inotify/file descriptor limits to avoid "Too many open files"
# =====================================================================

K8S_STABLE_SERIES="${K8S_STABLE_SERIES:-v1.31}"   # e.g. v1.30, v1.31

log() { echo -e "[\e[1;34m$(date +%H:%M:%S)\e[0m] $*"; }

raise_sys_limits() {
  sudo tee /etc/sysctl.d/99-inotify.conf >/dev/null <<'EOF' || true
fs.inotify.max_user_watches=524288
EOF
  sudo tee /etc/sysctl.d/99-file-max.conf >/dev/null <<'EOF' || true
fs.file-max=1000000
EOF
  sudo sysctl --system >/dev/null || true
  ulimit -n 1048576 || true
  sudo tee /etc/security/limits.d/99-nofile.conf >/dev/null <<'EOF' || true
* soft nofile 1048576
* hard nofile 1048576
EOF
}

fix_old_k8s_repo() {
  # Remove deprecated apt.kubernetes.io entries
  [[ -f /etc/apt/sources.list.d/kubernetes.list ]] && sudo sed -i '/apt\.kubernetes\.io/d' /etc/apt/sources.list.d/kubernetes.list || true
  [[ -f /etc/apt/sources.list.d/kubernetes.list && ! -s /etc/apt/sources.list.d/kubernetes.list ]] && sudo rm -f /etc/apt/sources.list.d/kubernetes.list || true
  sudo sed -i '/apt\.kubernetes\.io/d' /etc/apt/sources.list || true
}

log "=== Preflight: raising system limits & fixing old Kubernetes repo ==="
raise_sys_limits
fix_old_k8s_repo

log "=== Removing old Docker versions ==="
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y "$pkg" >/dev/null 2>&1 || true
done

log "=== Installing Docker Engine (official repo) ==="
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker’s official GPG key & repo
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod 0644 /etc/apt/keyrings/docker.asc

UBU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBU_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable Docker & add current user to group
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true
log "Docker installed. Re-login or run 'newgrp docker' to use docker without sudo."
log "Verifying Docker (using sudo for now)..."
sudo docker run --rm hello-world || true

log "=== Installing Minikube (latest) ==="
curl -fsSLO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube
rm -f minikube-linux-amd64
minikube version || true

log "=== Installing kubectl from pkgs.k8s.io (${K8S_STABLE_SERIES}) ==="
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings

# Correct GPG handling: dearmor to a keyring and set perms
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_STABLE_SERIES}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_STABLE_SERIES}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y kubectl
kubectl version --client || true

log '=== Installation complete! ==='
echo "Use Docker without sudo after re-login (or run 'newgrp docker')."
echo "Start Minikube with Docker driver:"
echo "  minikube start --driver=docker"
