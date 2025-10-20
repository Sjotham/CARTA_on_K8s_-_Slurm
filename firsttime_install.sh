#!/bin/bash
set -e

echo "=== Removing old Docker versions ==="
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg || true
done

echo "=== Installing Docker Engine ==="
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker’s official GPG key and repo
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${UBUNTU_CODENAME}) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Enable Docker for the current user
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

echo "Docker installed successfully. Log out and back in to use docker without sudo."

# Optional: verify Docker
sudo docker run --rm hello-world

echo "=== Installing Minikube ==="
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm -f minikube-linux-amd64
minikube version

echo "=== Installing kubectl ==="
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl

sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg \
  https://packages.cloud.google.com/apt/doc/apt-key.gpg
echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] \
  https://apt.kubernetes.io/ kubernetes-xenial main" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y kubectl

echo "=== Verifying kubectl installation ==="
kubectl version --client

echo "=== Installation complete! ==="
echo "Now you can start Minikube with:"
echo "  minikube start --driver=docker"
