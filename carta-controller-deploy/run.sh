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

# Install Node.js v22.x (current LTS) from NodeSource
# https://github.com/nodesource/distributions
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -

# Install Node.js (includes NPM)
sudo apt-get install -yq nodejs

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#install-carta-controller
# Install carta-controller (includes frontend dependency)
sudo npm install -g --unsafe-perm carta-controller

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#set-up-users-and-directories
# Create a group to identify CARTA users
sudo groupadd -f carta-users

# Create a 'carta' user to run the controller
if ! id -u carta &>/dev/null; then
  sudo useradd --system --create-home --home /var/lib/carta --shell=/bin/bash --user-group carta
fi

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
  sudo -u carta -H bash -lc "
    openssl genrsa -out /etc/carta/carta_private.pem 4096
    openssl rsa -in /etc/carta/carta_private.pem -outform PEM -pubout -out /etc/carta/carta_public.pem
  "
fi

sudo mkdir -p /etc/carta
if [ -f scripts/config.json ]; then
  sudo -u carta -H bash -lc "
    cp scripts/config.json /etc/carta
  "
fi

# https://carta-controller.readthedocs.io/en/dev/step_by_step.html#test-carta-controller
# Create a test user in the 'carta-users' group
if ! id -u alice &>/dev/null; then
  sudo useradd --create-home --groups carta-users alice
  sudo passwd alice
fi

# # Copy test image to user's home directory
# sudo -u carta -H bash -lc "
#  cp /usr/share/carta/default.fits /home/alice/test.fits || true
#  chown alice /home/alice/test.fits || true
# "

# --------------------------------------------------------------------------------
# Run controller from carta's home to avoid permission issues
# --------------------------------------------------------------------------------
APP_DIR="/var/lib/carta/carta-controller"

# Make sure the parent directory exists
sudo mkdir -p "${APP_DIR}"
# Ensure carta owns everything under that directory
sudo chown -R carta: "${APP_DIR}"

# If the repo doesn't exist yet, clone it
if [ ! -d "${APP_DIR}/.git" ]; then
  echo "Cloning CARTA controller into ${APP_DIR}..."
  sudo -u carta -H bash -lc "
    cd $(dirname "${APP_DIR}")
    git clone --recursive https://github.com/CARTAvis/carta-controller.git $(basename "${APP_DIR}")
  "
fi



sudo -u carta -H env APP_DIR="$APP_DIR" bash -lc '
  set -e
  mkdir -p /var/lib/carta

  if [ ! -d "$APP_DIR" ]; then
    echo "Cloning CARTA controller into $APP_DIR..."
    cd /var/lib/carta
    # Make sure carta owns the repo
    git clone --recursive https://github.com/CARTAvis/carta-controller.git "$(basename "$APP_DIR")"
  elif [ -d "$APP_DIR/.git" ]; then
    echo "Updating CARTA controller repo in $APP_DIR..."
    cd "$APP_DIR"
    git fetch --all --tags
    git pull --rebase --autostash || true
  else
    echo "Warning: $APP_DIR exists but is not a git repo. Skipping clone and update."
  fi

  # Ensure submodules initialized (idempotent)
  if [ -d "$APP_DIR/.git" ]; then
    cd "$APP_DIR"
    git submodule update --init --recursive
  fi
'

# Ensure the PID dir is owned by carta (recommended)
sudo mkdir -p /var/run/carta
sudo chown carta: /var/run/carta


# Start controller in background (as carta)
echo "Starting CARTA controller..."
sudo -u carta -H env APP_DIR="$APP_DIR" bash -lc '
  cd /var/lib/carta/carta-controller
  npm install --no-audit --no-fund --progress=false
  nohup npm run start >/var/log/carta/controller.out 2>&1 &
  echo $! > /var/run/carta/controller.pid
'
