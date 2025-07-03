#!/usr/bin/env bash
set -euo pipefail

# 1) Read the RKE2 server token silently
read -s -p "Enter RKE2 server token: " TOKEN
echo

# 2) Ensure we're root
if (( EUID != 0 )); then
  echo "ERROR: Must be run as root."
  exit 1
fi

# 3) Pick the user for KUBECONFIG installation
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  KUBE_USER="$SUDO_USER"
else
  KUBE_USER="root"
fi
USER_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
KUBE_DIR="$USER_HOME/.kube"
ADMIN_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"

# 4) Write RKE2 config
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

# 5) Install RKE2 (tar) & start server
curl -sfL https://get.rke2.io | INSTALL_RKE2_METHOD='tar' sh -
systemctl enable rke2-server.service
systemctl start  rke2-server.service

# 6) Install kubectl
echo "Installing kubectl..."
K8S_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl

# 7) Install k9s (amd64)
echo "Installing k9s..."
curl -L "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz" -o k9s.tar.gz
tar zxvf k9s.tar.gz k9s
install -o root -g root -m 0755 k9s /usr/local/bin/k9s
rm k9s k9s.tar.gz

# 8) Install Helm
echo "Installing Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# 9) Copy admin kubeconfig to user
echo "Copying admin kubeconfig to ${KUBE_USER}..."
mkdir -p "${KUBE_DIR}"
cp "${ADMIN_KUBECONFIG}" "${KUBE_DIR}/config"
chown -R "${KUBE_USER}:${KUBE_USER}" "${KUBE_DIR}"
chmod 600 "${KUBE_DIR}/config"

# 10) Wait for API to be ready
echo "Waiting for Kubernetes API..."
until kubectl version --short >/dev/null 2>&1; do sleep 5; done

# 11) Install Argo CD via Helm
echo "Installing Argo CD in namespace argocd..."
kubectl create ns argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm -n argocd upgrade --install argocd argo/argo-cd --version 8.1.2

# 12) Retrieve & show initial admin password
echo
echo "===== Argo CD initial admin password ====="
PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "${PASSWORD}"
echo "=========================================="
echo
read -p "Press [ENTER] once you've copied the password to delete the secret..." _

# 13) Securely delete the secret
kubectl -n argocd delete secret argocd-initial-admin-secret
echo "Argo CD initial-admin-secret has been deleted."

echo
echo "✔ RKE2, kubectl, k9s, Helm, and Argo CD are all installed."
echo "✔ kubeconfig is at ${KUBE_DIR}/config (owned by ${KUBE_USER})."
echo "You can now interact with your cluster and Argo CD:"
echo "  kubectl get nodes"
echo "  k9s"
echo "  helm -n argocd list"
