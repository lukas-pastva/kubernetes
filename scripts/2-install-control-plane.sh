#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 2-install-control-plane.sh
# ────────────────────────────────────────────────────────────────────────────
# Installs an RKE2 control-plane node, Argo CD, bootstraps your Git repo,
# and (optionally) seeds Rancher on the same cluster.
#
# Environment variables you can pre-seed:
#   RANCHER_TOKEN       –  RKE2 cluster-join token
#   GIT_REPO_URL        –  SSH URL of your Git repo (e.g. git@host:org/repo.git)
#   SSH_PRIVATE_KEY     –  private key that grants read-write access to repo
#   ARGOCD_PASS         –  desired Argo CD *admin* password (plain text)
#   RANCHER_PASS        –  desired Rancher admin password
#   INSTALL_RANCHER     –  "true" → also install Rancher & bootstrap password
###############################################################################

###############################################################################
# Auto-escalate – relaunch under sudo if not root
###############################################################################
if (( EUID != 0 )); then
  echo "⎈  Not running as root – re-launching with sudo…"
  exec sudo -E bash "$0" "$@"
fi

###############################################################################
# Variables & interactive fall-backs
###############################################################################
KUBE_USER="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$KUBE_USER" | cut -d: -f6)"
KUBE_DIR="$USER_HOME/.kube"
ADMIN_KUBECONFIG="/etc/rancher/rke2/rke2.yaml"

TOKEN="${RANCHER_TOKEN:-}"
GIT_REPO_URL="${GIT_REPO_URL:-}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
ARGOCD_PASS="${ARGOCD_PASS:-}"
RANCHER_PASS="${RANCHER_PASS:-}"

[[ -z "$TOKEN"        ]] && read -s -p "Enter RKE2 join token                : " TOKEN && echo
[[ -z "$GIT_REPO_URL" ]] && read    -p "Enter Git repo SSH URL             : " GIT_REPO_URL
if [[ -z "$SSH_PRIVATE_KEY" ]]; then
  echo "Paste SSH private key, end with EOF (Ctrl-D):"
  SSH_PRIVATE_KEY="$(cat)"
fi
[[ -z "$ARGOCD_PASS"  ]] && read -s -p "Enter desired Argo CD admin password: " ARGOCD_PASS && echo

###############################################################################
# Ensure *htpasswd* is available (apache2-utils or httpd-tools)
###############################################################################
if ! command -v htpasswd >/dev/null; then
  echo "Installing *htpasswd* utility…"
  if   command -v apt-get >/dev/null; then
       apt-get update -qq
       DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2-utils
  elif command -v dnf     >/dev/null; then dnf install  -y -q httpd-tools
  elif command -v yum     >/dev/null; then yum install  -y -q httpd-tools
  else
    echo "ERROR: cannot install 'htpasswd' automatically." >&2
    exit 1
  fi
fi

###############################################################################
# Hash the Argo CD password (bcrypt, $2a$…) – required by the Helm chart
###############################################################################
ARGOCD_HASH="$(
  htpasswd -nbBC 10 "" "$ARGOCD_PASS" \
    | tr -d ':\n' \
    | sed 's/\$2y/\$2a/'
)"

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
# Tooling – kubectl · k9s · Helm  (latest stable versions)
###############################################################################
K8S_VERSION="$(curl -sL https://dl.k8s.io/release/stable.txt)"
curl -sL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

curl -sL "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz" |
  tar zx -C /usr/local/bin k9s
chmod 0755 /usr/local/bin/k9s

curl -fsSL https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

###############################################################################
# kubeconfig for the chosen user
###############################################################################
mkdir -p "$KUBE_DIR"
cp "$ADMIN_KUBECONFIG" "$KUBE_DIR/config"
chown -R "$KUBE_USER":"$KUBE_USER" "$KUBE_DIR"
chmod 600 "$KUBE_DIR/config"

echo "Waiting for Kubernetes API to become available…"
until kubectl version >/dev/null 2>&1; do sleep 5; done

###############################################################################
# Argo CD installation (with *hashed* admin password)
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
  --set-string configs.secret.argocdServerAdminPassword="$ARGOCD_HASH"

echo -e "\n✔ Argo CD installed – user: *admin*, password: '${ARGOCD_PASS}'"

###############################################################################
# Git repo SSH secret for Argo CD
###############################################################################
echo "Creating Git SSH secret in argocd…"

# Turn literal '\n' back into real line-breaks
printf -v KEY_STR '%b\n' "${SSH_PRIVATE_KEY//\\n/$'\n'}"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: git-ssh-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  sshPrivateKey: |
$(echo "$KEY_STR" | sed 's/^/    /')
  type: git
  url: $GIT_REPO_URL
EOF

###############################################################################
# Default AppProject + "app-of-apps" Application bootstrap
###############################################################################
echo "Bootstrapping app-of-apps…"

sleep 10

# ⬇️  If the “default” AppProject already exists, do NOT recreate it
if ! kubectl get appproject default -n argocd >/dev/null 2>&1; then
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
  namespace: argocd
spec:
  description: default project
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  destinations:
  - namespace: '*'
    server: '*'
  orphanedResources:
    warn: true
  sourceRepos:
  - '*'
EOF
else
  echo "✔ AppProject 'default' already present – skipping."
fi

# The Application can be safely (re-)applied every time
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $GIT_REPO_URL
    path: charts/internal/app-of-apps
    targetRevision: main
    helm:
      valueFiles:
      - ../../../app-of-apps.yaml
  destination:
    name: in-cluster
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

###############################################################################
# Optional – Rancher bootstrap
###############################################################################
if [[ "${INSTALL_RANCHER:-false}" == "true" ]]; then
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
# All done!
###############################################################################
echo
echo "🎉  Installation finished."
echo "    kubeconfig for ${KUBE_USER}: $KUBE_DIR/config"

# ── self-destruct ────────────────────────────────────────────────────────────
rm -- "$0" 2>/dev/null || true
