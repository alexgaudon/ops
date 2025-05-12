#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Install Caddy
echo "Installing Caddy..."
apt update
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install -y caddy

# Download Caddyfile from GitHub
echo "Downloading Caddyfile from GitHub..."
curl -sSL "https://raw.githubusercontent.com/alexgaudon/ops/main/proxy/Caddyfile" -o /etc/caddy/Caddyfile

# Ensure proper permissions
chown -R caddy:caddy /etc/caddy
chmod 644 /etc/caddy/Caddyfile

# Restart Caddy to apply changes
echo "Restarting Caddy service..."
systemctl restart caddy
systemctl enable caddy

# Verify Caddy is running
if systemctl is-active --quiet caddy; then
    echo "Caddy has been successfully installed and is running"
    echo "You can check the status with: systemctl status caddy"
else
    echo "Error: Caddy service is not running. Please check the logs with: journalctl -u caddy"
    exit 1
fi 