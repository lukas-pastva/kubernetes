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

###############################################################################
# HISTORY WIPE (invoking user + root)
###############################################################################
echo "Wiping shell history…"
{
  unset HISTFILE
  history -c 2>/dev/null || true

  wipe() {                    # truncate & divert future writes to /dev/null
    local f="$1"; [ -e "$f" ] || return
    : > "$f" || true
    ln -sf /dev/null "$f" 2>/dev/null || true
  }

  wipe "$HOME/.bash_history"                  # current shell
  [ -f /root/.bash_history ] && wipe /root/.bash_history

  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    u_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    wipe "${u_home}/.bash_history"
  fi
} 2>/dev/null || true

# ── self-destruct ────────────────────────────────────────────────────────────
rm -- "$0" 2>/dev/null || true
