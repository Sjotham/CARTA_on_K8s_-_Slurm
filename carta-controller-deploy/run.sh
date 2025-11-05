#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=("-yq" "-o" "Dpkg::Options::=--force-confnew")

# From https://carta-controller.readthedocs.io/en/dev/step_by_step.html
# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#prerequisites
sudo apt-get update -yq
sudo apt-get install vim curl ca-certificates gnupg lsb-release git "${APT_OPTS[@]}"

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#install-mongodb
# Import public key for MongoDB repo
if [ ! -f /usr/share/keyrings/mongodb-server-8.0.gpg ]; then
  curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
fi

# Add MongoDB repository
if [ ! -f /etc/apt/sources.list.d/mongodb-org-8.0.list ]; then
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
fi

sudo apt-get update -yq

# Install MongoDB
sudo apt-get install mongodb-org "${APT_OPTS[@]}"

# Start MongoDB
sudo systemctl enable --now mongod

# Make MongoDB start automatically on system restart
# (already handled by enable --now)

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#install-carta-backend-and-other-required-packages
# Add CARTA PPA
sudo add-apt-repository -y ppa:cartavis-team/carta
sudo apt-get update -yq

# Install the backend package with all dependencies -y
sudo apt-get install carta-backend "${APT_OPTS[@]}"

# Install additional packages
sudo apt-get install g++ make build-essential libpam0g-dev "${APT_OPTS[@]}"

# --------------------------------------------------------------------------------
# Node.js setup (Option A): use nvm to install Node 20 LTS (fallback to Node 18 LTS)
# This avoids Node 24's ABI (node-v137) which breaks node-linux-pam builds.
# --------------------------------------------------------------------------------
install_nvm_and_node() {
  local target_user="$1"
  local node_major="${2:-20}"
  local fallback_major="${3:-18}"

  local user_home
  user_home=$(eval echo "~${target_user}")

  if [ ! -s "${user_home}/.nvm/nvm.sh" ]; then
    sudo -H -u "${target_user}" bash -lc 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash'
  fi

  sudo -H -u "${target_user}" bash -lc "
    export NVM_DIR=\"\$HOME/.nvm\"
    . \"\$NVM_DIR/nvm.sh\"
    nvm install ${node_major} || true
    if ! nvm ls ${node_major} >/dev/null 2>&1; then
      nvm install ${fallback_major}
      nvm alias default ${fallback_major}
    else
      nvm alias default ${node_major}
    fi
    nvm use default
    node -v
    npm -v
  "
}

TARGET_USER="${SUDO_USER:-$USER}"
install_nvm_and_node "${TARGET_USER}" 20 18

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#set-up-users-and-directories
# Create a group to identify CARTA users
sudo groupadd -f carta-users

# Create a 'carta' user to run the controller
if ! id -u carta &>/dev/null; then
  sudo useradd --system --create-home --home /var/lib/carta --shell=/bin/bash --user-group carta
fi

# Ensure nvm + Node LTS is installed for the 'carta' user as well
install_nvm_and_node "carta" 20 18

# Create a log directory owned by carta
sudo mkdir -p /var/log/carta
sudo chown carta: /var/log/carta

# Create a config directory owned by carta
sudo mkdir -p /etc/carta
sudo chown carta: /etc/carta

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#set-up-users-and-directories
# Add 'carta' user to the shadow group
sudo usermod -a --groups shadow carta

# install_carta_sudoers.sh is optional
if [ -f install_carta_sudoers.sh ]; then
  bash install_carta_sudoers.sh || echo "Warning: install_carta_sudoers.sh failed"
fi

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#install-and-configure-nginx
sudo apt-get install nginx "${APT_OPTS[@]}"

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#configure-ssl
# Install certbot (optional)
# sudo apt-get install certbot python3-certbot-nginx -y

# Run certbot and follow the prompts to generate the certificates
# Note the certificate and key locations which are printed out
# sudo certbot certonly --nginx

# Create an Nginx configuration file for CARTA
# sudo vim /etc/nginx/conf.d/carta.conf

# Restart Nginx
# sudo systemctl restart nginx

# Run carta-controller

# Switch to carta user
#sudo su - carta

# Generate private/public keys
if [ ! -f /etc/carta/carta_private.pem ]; then
  sudo openssl genrsa -out /etc/carta/carta_private.pem 4096
fi
sudo openssl rsa -in /etc/carta/carta_private.pem -outform PEM -pubout -out /etc/carta/carta_public.pem

sudo mkdir -p /etc/carta
if [ -f scripts/config.json ]; then
  sudo cp scripts/config.json /etc/carta
fi

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#start-carta-controller
# Switch back to user with sudo access
# (no-op)

# Copy test image to user's home directory
TARGET_USER="${SUDO_USER:-$USER}"
sudo cp /usr/share/carta/default.fits /home/$TARGET_USER/test.fits || true
sudo chown $TARGET_USER: /home/$TARGET_USER/test.fits || true

# --------------------------------------------------------------------------------
# Run controller from carta's home to avoid permission issues
# --------------------------------------------------------------------------------
APP_DIR="/var/lib/carta/carta-controller"

# Clone/update the repo as carta (keeps ownership/permissions correct)
if [ ! -d "${APP_DIR}" ]; then
  echo "Cloning CARTA controller into ${APP_DIR}..."
  sudo -u carta -H bash -lc "
    mkdir -p /var/lib/carta
    cd /var/lib/carta
    git clone --recursive https://github.com/CARTAvis/carta-controller.git
  "
else
  echo "Updating CARTA controller repo in ${APP_DIR}..."
  sudo -u carta -H bash -lc "
    cd ${APP_DIR}
    git fetch --all --tags
    git pull --rebase --autostash || true
    git submodule update --init --recursive
  "
fi

# Ensure submodules initialized (idempotent)
sudo -u carta -H bash -lc "
  cd ${APP_DIR}
  git submodule update --init --recursive
"

# Install dependencies for controller using carta's Node LTS (via nvm)
echo "Installing CARTA controller dependencies (as carta)..."
sudo -u carta -H bash -lc '
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
  nvm use default >/dev/null
  cd /var/lib/carta/carta-controller
  node -v
  npm -v
  npm install --no-audit --no-fund --progress=false
'

# Start controller in background (as carta)
echo "Starting CARTA controller..."
sudo -u carta -H bash -lc '
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
  nvm use default >/dev/null
  cd /var/lib/carta/carta-controller
  nohup npm run start >/var/log/carta/controller.out 2>&1 & disown
'
