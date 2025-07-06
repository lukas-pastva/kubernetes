#!/usr/bin/env bash
set -euo pipefail

(( EUID == 0 )) || { echo "ERROR: run as root." >&2; exit 1; }

###############################################################################
# Variables & kubeconfig location
###############################################################################
KUBE_USER="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
KUBE_DIR="$USER_HOME/.kube"
ADMIN_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
TOKEN="${RANCHER_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  read -s -p "Enter RKE2 join token: " TOKEN && echo
fi
###############################################################################
# RKE2 control-plane install
###############################################################################
mkdir -p /etc/rancher/rke2/
cat <<EOF >/etc/rancher/rke2/config.yaml
token: ${TOKEN}
cni:
  - cilium
disable:
  - rke2-canal
  - rke2-kube-proxy
  - rke2-ingress-nginx
EOF

curl -sfL https://get.rke2.io | INSTALL_RKE2_METHOD='tar' sh -
systemctl enable rke2-server.service
systemctl start  rke2-server.service

###############################################################################
# Tooling: kubectl • k9s • Helm
###############################################################################
K8S_VERSION="$(curl -sL https://dl.k8s.io/release/stable.txt)"
curl -sL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

curl -sL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz" | tar zx -C /usr/local/bin k9s
chmod 0755 /usr/local/bin/k9s

curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

###############################################################################
# kubeconfig for the chosen user
###############################################################################
mkdir -p "$KUBE_DIR"
cp "$ADMIN_KUBECONFIG" "$KUBE_DIR/config"
chown -R "$KUBE_USER":"$KUBE_USER" "$KUBE_DIR"
chmod 600 "$KUBE_DIR/config"

echo "Waiting for Kubernetes API…"
until kubectl version --short >/dev/null 2>&1; do sleep 5; done

###############################################################################
# Argo CD – password provided or prompted
###############################################################################
ARGOCD_PASS="${ARGOCD_PASS:-}"
if [[ -z "$ARGOCD_PASS" ]]; then
  read -s -p "Enter desired Argo CD admin password: " ARGOCD_PASS && echo
fi

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --version 8.1.2 \
  --set configs.secret.createSecret=true \
  --set-string configs.secret.argocdServerAdminPassword="$ARGOCD_PASS"

echo -e "\n✔ Argo CD installed – user *admin*, password '${ARGOCD_PASS}'"

###############################################################################
# Rancher bootstrap (only if requested)
###############################################################################
if [[ "${INSTALL_RANCHER:-false}" == "true" ]]; then
  RANCHER_PASS="${RANCHER_PASS:-}"
  if [[ -z "$RANCHER_PASS" ]]; then
    read -s -p "Enter Rancher admin password (bootstrapPassword): " RANCHER_PASS && echo
  fi

  kubectl get ns cattle-system >/dev/null 2>&1 || kubectl create ns cattle-system
  kubectl -n cattle-system create secret generic bootstrap-secret \
    --from-literal=bootstrapPassword="$RANCHER_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✔ Rancher bootstrap-secret created/updated."
fi

###############################################################################
# HISTORY WIPE (root + invoking user)
###############################################################################
echo "Wiping shell history…"
unset HISTFILE
history -c 2>/dev/null || true

for h in /root/.bash_history "/home/${KUBE_USER}"/.bash_history; do
  [ -f "$h" ] && rm -f "$h"
done

echo
echo "✔ Installation finished. kubeconfig: $KUBE_DIR/config"
