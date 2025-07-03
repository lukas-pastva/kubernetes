#!/usr/bin/env bash
set -euo pipefail

# Prompt silently for the join token
read -s -p "Enter RKE2 join token: " TOKEN
echo

# Prompt for the control-plane (or LB) IP or hostname
read -p "Enter control-plane (or load-balancer) IP/hostname: " SERVER_ADDR

# Ensure we're running as root
if (( EUID != 0 )); then
  echo "This script must be run as root. Exiting."
  exit 1
fi

# Create the RKE2 agent config dir
mkdir -p /etc/rancher/rke2/

# Write the agent config
cat <<EOF >/etc/rancher/rke2/config.yaml
token: ${TOKEN}
server: https://${SERVER_ADDR}:9345
EOF

# Install RKE2 agent (tar method)
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_METHOD='tar' sh -

# Enable & start
systemctl enable rke2-agent.service
systemctl start rke2-agent.service

echo "RKE2 agent installation complete."
