#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# RKE2 worker install
###############################################################################
# You can pre-seed the join token via $RANCHER_TOKEN.
# If it isn’t set, the script will prompt for it.
###############################################################################

# ── auto-escalate ────────────────────────────────────────────────────────────
if (( EUID != 0 )); then
  echo "⎈  Not running as root – re-launching with sudo…"
  exec sudo -E bash "$0" "$@"
fi

TOKEN="${RANCHER_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  read -s -p "Enter RKE2 join token: " TOKEN && echo
fi

read -p "Enter control-plane (or load-balancer) IP/hostname: " SERVER_ADDR

mkdir -p /etc/rancher/rke2/
cat <<EOF >/etc/rancher/rke2/config.yaml
token:  ${TOKEN}
server: https://${SERVER_ADDR}:9345
EOF

curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_METHOD='tar' sh -
systemctl enable rke2-agent.service
systemctl start  rke2-agent.service

echo "✔ RKE2 agent installation complete."


# ── self-destruct ────────────────────────────────────────────────────────────
rm -- "$0" 2>/dev/null || true
