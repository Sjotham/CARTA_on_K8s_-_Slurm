# Follow https://github.com/CARTAvis/carta-frontend

#!/bin/bash
set -e  # Exit if any command fails

sudo apt-get update

# Install Node.js v22.x (current LTS) from NodeSource
# https://github.com/nodesource/distributions
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -yq nodejs


echo "Installing cmake"
sudo apt-get install cmake  -y

# ------------------------------------------------------------------------------
# Install or update Emscripten SDK (emsdk) safely and idempotently
# ------------------------------------------------------------------------------

# Clone or update emsdk
if [ ! -d "emsdk" ]; then
  echo "Cloning emsdk repository..."
  git clone https://github.com/emscripten-core/emsdk.git
else
  echo "Updating existing emsdk repository..."
  cd emsdk
  git fetch --all --tags
  git pull --rebase --autostash || true
  cd ..
fi

# Enter emsdk directory
cd emsdk

# Install the latest SDK tools (only if not already installed)
if ! ./emsdk list | grep -q '\* latest'; then
  echo "Installing latest emsdk..."
  ./emsdk install latest
else
  echo "emsdk 'latest' is already installed."
fi

# Activate the latest SDK for the current user (safe to re-run)
echo "Activating latest emsdk..."
./emsdk activate latest

# Source environment variables for the current shell
echo "Activating emsdk environment..."
source ./emsdk_env.sh

# Return to previous directory
cd ..

# Clone the repositories (skip if already cloned)
if [ ! -d "carta-frontend" ]; then
  echo "Cloning CARTA frontend..."
  git clone --recursive https://github.com/CARTAvis/carta-frontend.git
fi

# Go back and start frontend

cd carta-frontend
npm install

npx --yes update-browserslist-db@latest

npm run build-libs
npm run build

echo "Starting CARTA frontend..."
npm run start &