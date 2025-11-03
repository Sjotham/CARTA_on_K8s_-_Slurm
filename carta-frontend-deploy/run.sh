# Follow https://github.com/CARTAvis/carta-frontend

#!/bin/bash
set -e  # Exit if any command fails

sudo apt-get update

sudo apt-get install cmake nodejs npm -y

git clone https://github.com/emscripten-core/emsdk.git

# Enter that directory
cd emsdk

# Fetch the latest version of the emsdk (not needed the first time you clone)
git pull

# Download and install the latest SDK tools.
./emsdk install latest

# Make the "latest" SDK "active" for the current user. (writes .emscripten file)
./emsdk activate latest

# Activate PATH and other environment variables in the current terminal
source ./emsdk_env.sh

cd ..

# Clone the repositories (skip if already cloned)
if [ ! -d "carta-frontend" ]; then
  echo "Cloning CARTA frontend..."
  git clone --recursive https://github.com/CARTAvis/carta-frontend.git
fi

# Go back and start frontend
cd carta-frontend
git submodule update --init --recursive
npm install

npx --yes update-browserslist-db@latest

npm run build-libs
npm run build

echo "Starting CARTA frontend..."
npm run start &