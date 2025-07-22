#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# RKE2 worker‑node installer
#
# • Pre‑seed the join token with $RANCHER_TOKEN or enter it at the prompt.
# • Prompts once for the control‑plane / LB address.
###############################################################################

# ── auto‑escalate ────────────────────────────────────────────────────────────
if (( EUID != 0 )); then
  echo "⎈  Not running as root – re‑launching with sudo…"
  exec sudo -E bash "$0" "$@"
fi

# ── gather input ─────────────────────────────────────────────────────────────
TOKEN="${RANCHER_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  read -r -s -p "Enter RKE2 join token: " TOKEN
  echo
fi

read -r -p "Enter control‑plane (or load‑balancer) IP/hostname: " SERVER_ADDR
if [[ -z "$SERVER_ADDR" ]]; then
  echo "❌ Control‑plane address cannot be empty." >&2
  exit 1
fi

# ── write config.yaml safely ─────────────────────────────────────────────────
mkdir -p /etc/rancher/rke2/

cat >/etc/rancher/rke2/config.yaml <<EOF
token:  "${TOKEN}"
server: "https://${SERVER_ADDR}:9345"
EOF

# ── install & start agent ────────────────────────────────────────────────────
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_METHOD='tar' sh -
systemctl enable rke2-agent.service
systemctl start  rke2-agent.service

echo "⏳ Waiting for rke2-agent to settle…"
sleep 3
systemctl --no-pager --output=short status rke2-agent.service

echo "✔ RKE2 agent installation complete."

# ── self‑destruct ────────────────────────────────────────────────────────────
rm -- "$0" 2>/dev/null || true
