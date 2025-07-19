#!/usr/bin/env bash
set -euo pipefail
###############################################################################
# 1-install-control-plane.sh
# ────────────────────────────────────────────────────────────────────────────
# Installs an RKE2 control‑plane node, Argo CD, bootstraps your Git repo,
# and (optionally) seeds Rancher on the same cluster.
#
# New in this version
# ───────────────────
# • OAuth2 secrets support (unchanged from previous patch).
# • S‑3 support extended:
#     – If *loki*, *thanos* or *tempo* selected ⇒ secret **monitoring‑s3**
#       (plain creds as before).
#     – **If *thanos* is selected**, the same secret ALSO gains an
#       `objstore.yml` entry for Thanos (S‑3 object storage config).
#       • Optional env var **S3_BUCKET** overrides the bucket name
#         (defaults to `thanos`).
###############################################################################

###############################################################################
# Auto‑escalate – relaunch under sudo if not root
###############################################################################
if (( EUID != 0 )); then
  echo "⎈  Not running as root – re‑launching with sudo…"
  exec sudo -E bash "$0" "$@"
fi

###############################################################################
# Variables & interactive fall‑backs
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
GRAFANA_PASS="${GRAFANA_PASS:-}"
SELECTED_APPS="${SELECTED_APPS:-}"

# ── S‑3 credentials ─────────────────────────────────────────────────────────
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-}"
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_BUCKET="${S3_BUCKET:-thanos}"   # used inside objstore.yml (Thanos only)

[[ -z "$TOKEN"        ]] && read -s -p "Enter RKE2 join token                 : " TOKEN && echo
[[ -z "$GIT_REPO_URL" ]] && read    -p "Enter Git repo SSH URL              : " GIT_REPO_URL
if [[ -z "$SSH_PRIVATE_KEY" ]]; then
  echo "Paste SSH private key, end with EOF (Ctrl‑D):"
  SSH_PRIVATE_KEY="$(cat)"
fi
[[ -z "$ARGOCD_PASS"  ]] && read -s -p "Enter desired Argo CD admin password : " ARGOCD_PASS && echo

# prompt for S‑3 creds only if needed
if [[  " ${SELECTED_APPS} " =~ [[:space:]]loki[[:space:]]    ]] || \
   [[  " ${SELECTED_APPS} " =~ [[:space:]]thanos[[:space:]]  ]] || \
   [[  " ${SELECTED_APPS} " =~ [[:space:]]tempo[[:space:]]   ]]; then
  [[ -z "$S3_ACCESS_KEY_ID"     ]] && read    -p "Enter S3_ACCESS_KEY_ID      : " S3_ACCESS_KEY_ID
  [[ -z "$S3_SECRET_ACCESS_KEY" ]] && read -s -p "Enter S3_SECRET_ACCESS_KEY : " S3_SECRET_ACCESS_KEY && echo
  [[ -z "$S3_ENDPOINT"          ]] && read    -p "Enter S3_ENDPOINT (https://): " S3_ENDPOINT
fi

###############################################################################
# Ensure *htpasswd* is available (apache2‑utils or httpd‑tools)
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
# Hash the Argo CD password (bcrypt, $2a$…)
###############################################################################
ARGOCD_HASH="$(
  htpasswd -nbBC 10 "" "$ARGOCD_PASS" \
    | tr -d ':\n' \
    | sed 's/\$2y/\$2a/'
)"

###############################################################################
# RKE2 control‑plane install  (unchanged) …
###############################################################################
mkdir -p /etc/rancher/rke2/
cat <<EOF >/etc/rancher/rke2/config.yaml
token: ${TOKEN}

node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
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
# Tooling – kubectl · k9s · Helm (unchanged) …
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
# kubeconfig for the chosen user (unchanged)
###############################################################################
mkdir -p "$KUBE_DIR"
cp "$ADMIN_KUBECONFIG" "$KUBE_DIR/config"
chown -R "$KUBE_USER":"$KUBE_USER" "$KUBE_DIR"
chmod 600 "$KUBE_DIR/config"

echo "Waiting for Kubernetes API to become available…"
until kubectl version >/dev/null 2>&1; do sleep 5; done

###############################################################################
# Git repo SSH secret for Argo CD  (unchanged) …
###############################################################################
echo "Creating Git SSH secret in argocd…"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create ns argocd
# convert literal '\n' → real newlines
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
# Argo CD installation … (unchanged)
###############################################################################
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace --version 8.1.2 \
  --set configs.secret.createSecret=true \
  --set-string configs.secret.argocdServerAdminPassword="$ARGOCD_HASH"

echo -e "\n✔ Argo CD installed – user: *admin*, password: '${ARGOCD_PASS}'"

###############################################################################
# Default AppProject + app‑of‑apps Application bootstrap (unchanged)
###############################################################################
echo "Bootstrapping app‑of‑apps…"
sleep 10
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
fi

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
# Optional – Rancher bootstrap (unchanged)
###############################################################################
if [[ "${INSTALL_RANCHER:-false}" == "true" ]]; then
  [[ -z "$RANCHER_PASS" ]] && read -s -p "Enter Rancher admin password (bootstrapPassword): " RANCHER_PASS && echo
  kubectl get ns cattle-system >/dev/null 2>&1 || kubectl create ns cattle-system
  kubectl -n cattle-system create secret generic bootstrap-secret \
    --from-literal=bootstrapPassword="$RANCHER_PASS" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "✔ Rancher bootstrap-secret created/updated."
fi

###############################################################################
# Prepare argo‑workflows & other helper secrets (unchanged)
###############################################################################
has_event_app=false
for _app in $SELECTED_APPS; do
  [[ "$_app" == event-* ]] && has_event_app=true && break
done

if [[  " ${SELECTED_APPS} " =~ [[:space:]]argo-helm-toggler[[:space:]]  ]] || \
   [[  " ${SELECTED_APPS} " =~ [[:space:]]argo-app-forge[[:space:]]     ]] || \
   [[ "$has_event_app" == "true" ]]; then
  kubectl get ns argo-workflows >/dev/null 2>&1 || kubectl create ns argo-workflows
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: git-ssh-key
  namespace: argo-workflows
type: Opaque
stringData:
  GIT_REPO_SSH: |
$(echo "$KEY_STR" | sed 's/^/    /')
EOF
  if [[ "$has_event_app" == "true" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: event
  namespace: argo-workflows
type: Opaque
stringData:
  ARGOCD_PASSWORD: "${ARGOCD_PASS}"
  ARGOCD_USERNAME: "admin"
  GIT_SSH_KEY: |
$(echo "$KEY_STR" | sed 's/^/    /')
  GITOPS_REPO: "${GIT_REPO_URL}"
  GIT_EMAIL: "user@argo-init.com"
  GIT_USER: "argo-init"
EOF
  fi
fi

###############################################################################
# Grafana admin secret for kube‑prometheus‑stack (unchanged)
###############################################################################
if [[ " ${SELECTED_APPS} " =~ [[:space:]]kube-prometheus-stack[[:space:]] ]]; then
  [[ -z "$GRAFANA_PASS" ]] && GRAFANA_PASS="$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c10)"
  kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring
  kubectl -n monitoring create secret generic grafana-admin-secret \
    --from-literal=admin-user="admin" \
    --from-literal=admin-password="${GRAFANA_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

###############################################################################
# ── NEW: monitoring‑s3 secret (+ objstore.yml for Thanos) ───────────────────
###############################################################################
if [[  " ${SELECTED_APPS} " =~ [[:space:]]loki[[:space:]]    ]] || \
   [[  " ${SELECTED_APPS} " =~ [[:space:]]thanos[[:space:]]  ]] || \
   [[  " ${SELECTED_APPS} " =~ [[:space:]]tempo[[:space:]]   ]]; then
  echo "↻  Applying monitoring‑s3 secret…"
  kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring

  # base secret with the three literals
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: monitoring-s3
  namespace: monitoring
type: Opaque
stringData:
  S3_ACCESS_KEY_ID:      "${S3_ACCESS_KEY_ID}"
  S3_SECRET_ACCESS_KEY:  "${S3_SECRET_ACCESS_KEY}"
  S3_ENDPOINT:           "${S3_ENDPOINT}"
EOF

  # add objstore.yml if Thanos selected
  if [[ " ${SELECTED_APPS} " =~ [[:space:]]thanos[[:space:]] ]]; then
    OBJSTORE_YML=$(cat <<YAML
type: s3
config:
  bucket: ${S3_BUCKET}
  endpoint: ${S3_ENDPOINT}
  access_key: ${S3_ACCESS_KEY_ID}
  secret_key: ${S3_SECRET_ACCESS_KEY}
  insecure: true
YAML
)
    kubectl -n monitoring patch secret monitoring-s3 \
      --type merge \
      --patch "$(cat <<EOF
stringData:
  objstore.yml: |
$(echo "${OBJSTORE_YML}" | sed 's/^/    /')
EOF
)"
    echo "✔ monitoring‑s3 secret now contains objstore.yml for Thanos."
  fi
fi

###############################################################################
# OAuth2 application secrets (unchanged)
###############################################################################
if [[ -n "${OAUTH2_APPS:-}" ]]; then
  for APP in $(echo "$OAUTH2_APPS" | tr ',' ' ' | xargs); do
    NS="$APP"
    PREF=$(echo "$APP" | tr '[:lower:]-' '[:upper:]_')
    eval CLIENT_ID="\${${PREF}_CLIENT_ID:-}"
    eval CLIENT_SECRET="\${${PREF}_CLIENT_SECRET:-}"
    eval COOKIE_SECRET="\${${PREF}_COOKIE_SECRET:-}"
    eval REDIS_PASSWORD="\${${PREF}_REDIS_PASSWORD:-}"

    [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]] && {
      echo "⚠️  Skipping ${APP} – CLIENT_ID / CLIENT_SECRET not set." >&2
      continue
    }

    kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"
    kubectl -n "$NS" create secret generic "$NS" \
      --from-literal=client-id="$CLIENT_ID" \
      --from-literal=client-secret="$CLIENT_SECRET" \
      --from-literal=cookie-secret="$COOKIE_SECRET" \
      --from-literal=redis-password="$REDIS_PASSWORD" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
fi

###############################################################################
# Force Argo CD refresh & finish
###############################################################################
echo; echo "⏳ Waiting 10s before forcing Argo CD refresh…"; sleep 10
kubectl -n argocd annotate application app-of-apps \
  argocd.argoproj.io/refresh=hard --overwrite || true

echo; echo "🎉  Installation finished."
echo "    kubeconfig for ${KUBE_USER}: $KUBE_DIR/config"

# self‑destruct
rm -- "$0" 2>/dev/null || true
