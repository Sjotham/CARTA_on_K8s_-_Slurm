# From https://carta-controller.readthedocs.io/en/dev/step_by_step.html
sudo apt-get install vim curl

# Import public key for MongoDB repo
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

# Add MongoDB repository
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

sudo apt-get update

# Install MongoDB
sudo apt-get install mongodb-org

# Start MongoDB
sudo systemctl start mongod

# Make MongoDB start automatically on system restart
# sudo systemctl enable mongod

# Add CARTA PPA
sudo add-apt-repository ppa:cartavis-team/carta
sudo apt-get update

# Install the backend package with all dependencies
sudo apt-get install carta-backend

# Install additional packages
sudo apt-get install g++ make build-essential libpam0g-dev


# Install the latest Node.js LTS repo
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -

# Install Node.js (includes NPM)
sudo apt-get install nodejs -y

# Create a group to identify CARTA users
sudo groupadd carta-users

# Create a 'carta' user to run the controller
sudo useradd --system --create-home --home /var/lib/carta --shell=/bin/bash --user-group carta

# Create a log directory owned by carta
sudo mkdir -p /var/log/carta
sudo chown carta: /var/log/carta

# Create a config directory owned by carta
sudo mkdir -p /etc/carta
sudo chown carta: /etc/carta


# Add 'carta' user to the shadow group
sudo usermod -a --groups shadow carta

bash install_carta_sudoers.sh


sudo mkdir /etc/carta
sudo cp scripts/config.json /etc/carta

if [ ! -d "carta-controller" ]; then
  echo "Cloning CARTA controller..."
  git clone --recursive  https://github.com/CARTAvis/carta-controller.git
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
