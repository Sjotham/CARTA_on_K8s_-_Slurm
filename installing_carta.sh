#!/bin/bash
#
# install_carta.sh
# Script to install CARTA backend and controller, plus configure MongoDB, Node.js, and Nginx
# NOTE: You must run this script as a sudo-capable user.

set -e

echo "Installing dependencies..."
sudo apt-get update
sudo apt-get install -y vim curl g++ make build-essential libpam0g-dev nginx certbot python3-certbot-nginx

echo "Setting up MongoDB repository..."
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "Adding MongoDB repo..."
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/8.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list

sudo apt-get update
sudo apt-get install -y mongodb-org

echo "Starting MongoDB..."
sudo systemctl start mongod
sudo systemctl enable mongod

echo "Adding CARTA PPA..."
sudo add-apt-repository -y ppa:cartavis-team/carta
sudo apt-get update
sudo apt-get install -y carta-backend carta-backend-beta

echo "Installing Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs

echo "Installing carta-controller..."
sudo npm install -g --unsafe-perm carta-controller@beta

echo "Setting up system users and directories..."
sudo groupadd -f carta-users
sudo useradd --system --create-home --home /var/lib/carta --shell=/bin/bash --user-group carta

sudo mkdir -p /var/log/carta
sudo mkdir -p /etc/carta
sudo chown carta: /var/log/carta
sudo chown carta: /etc/carta

sudo usermod -a --groups shadow carta

echo "Creating sudoers file for carta user..."
sudo tee /etc/sudoers.d/carta_controller > /dev/null <<EOF
# carta user can run the carta_backend command as any user in the carta-users group without entering password
carta ALL=(%carta-users) NOPASSWD:SETENV: /usr/bin/carta_backend

# carta user can run the kill script as any user in the carta-users group without entering password
carta ALL=(%carta-users) NOPASSWD: /usr/bin/carta-kill-script
EOF

echo "Installing Nginx..."
sudo apt-get install -y nginx

echo "Obtaining SSL certificates (you will be prompted)..."
echo "Remember to adjust the domain name below (carta.example.com)!"
# Uncomment and adjust:
# sudo certbot certonly --nginx

echo "Creating Nginx configuration..."
sudo tee /etc/nginx/conf.d/carta.conf > /dev/null <<EOF
server {
    listen 443 ssl;
    server_name carta.example.com;

    ssl_certificate /etc/letsencrypt/live/carta.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/carta.example.com/privkey.pem;

    location / {
        proxy_set_header   X-Forwarded-For \$remote_addr;
        proxy_pass http://localhost:8000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}

server {
    server_name carta.example.com;
    listen 80;
    listen [::]:80;
    return 301 https://\$host\$request_uri;
}
EOF

sudo systemctl restart nginx

echo "Switching to carta user to generate keys..."
sudo -u carta bash <<EOF
openssl genrsa -out /etc/carta/carta_private.pem 4096
openssl rsa -in /etc/carta/carta_private.pem -outform PEM -pubout -out /etc/carta/carta_public.pem
EOF

echo "Creating CARTA controller config..."
sudo tee /etc/carta/config.json > /dev/null <<EOF
{
    "\$schema": "https://cartavis.org/schemas/controller_config_schema_2.json",
    "authProviders": {
        "pam": {
            "publicKeyLocation": "/etc/carta/carta_public.pem",
            "privateKeyLocation": "/etc/carta/carta_private.pem",
            "issuer": "carta.example.com"
        }
    },
    "database": {
        "uri": "mongodb://localhost:27017",
        "databaseName": "CARTA"
    },
    "serverPort": 8000,
    "serverInterface": "localhost",
    "processCommand": "/usr/bin/carta_backend",
    "killCommand": "/usr/bin/carta-kill-script",
    "rootFolderTemplate": "/home/{username}",
    "baseFolderTemplate": "/home/{username}",
    "logFile":"/var/log/carta/controller.log",
    "dashboard": {
        "bannerColor": "#d2dce5",
        "backgroundColor": "#f6f8fa",
        "infoText": "Welcome to the CARTA server.",
        "loginText": "<span>Please enter your login credentials:</span>",
        "footerText": "<span>If you have any problems, comments or suggestions, please <a href='mailto:admin@carta.example.com'>contact us.</a></span>"
    }
}
EOF

echo "Creating CARTA backend config..."
sudo tee /etc/carta/backend.json > /dev/null <<EOF
{
    "\$schema": "https://cartavis.org/schemas/preference_backend_schema_2.json",
    "backendConfigVersion": "2.0",
    "idle_timeout": 14400,
    "omp_threads": 8,
    "exit_timeout": 0,
    "initial_timeout": 30
}
EOF

echo "Creating a test user (alice)..."
sudo useradd --create-home --groups carta-users alice
echo "Set a password for alice manually with: sudo passwd alice"

echo "Copying test FITS file..."
sudo cp /usr/share/carta/default.fits /home/alice/test.fits
sudo chown alice: /home/alice/test.fits

echo ""
echo "All setup steps completed!"
echo "Next steps manually:"
echo "1. Set password for alice: sudo passwd alice"
echo "2. Obtain SSL certs: sudo certbot certonly --nginx (and edit nginx conf with correct domain)"
echo "3. Start the controller as the carta user:"
echo "   sudo su - carta"
echo "   carta-controller"
echo ""
echo "To test, you can also run:"
echo "   sudo su - carta"
echo "   carta-controller --verbose --test alice"

