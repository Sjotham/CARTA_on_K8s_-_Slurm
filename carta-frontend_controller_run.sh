#!/bin/bash
set -e  # Exit if any command fails

# Clone the repositories (skip if already cloned)
if [ ! -d "carta-frontend" ]; then
  echo "Cloning CARTA frontend..."
  git clone https://github.com/CARTAvis/carta-frontend.git
fi

if [ ! -d "carta-controller" ]; then
  echo "Cloning CARTA controller..."
  git clone https://github.com/CARTAvis/carta-controller.git
fi

# Update submodules if needed
cd carta-controller
git submodule update --init --recursive

# Install dependencies for controller
echo "Installing CARTA controller dependencies..."
npm install

# Start controller in background
echo "Starting CARTA controller..."
npm run start &

# Go back and start frontend
cd ../carta-frontend
echo "Installing CARTA frontend dependencies..."
npm install

echo "Starting CARTA frontend..."
npm run start
