# Kubernetes GitOps Stack

This is an internal GitOps-based Kubernetes platform integrating **RKE2**, **Rancher**, and **ArgoCD** for streamlined cluster and application management.

---

## 🚀 Overview

**Key Components:**

- **RKE2:** Kubernetes runtime
- **Rancher:** Cluster lifecycle and infrastructure management
- **ArgoCD:** GitOps-driven deployments (App-of-Apps pattern)

---

## 📁 Repository Structure

```
argocd/
  ├── applications.yaml
  └── README.md

charts/
  ├── external/
  └── internal/

scripts/
  ├── 1-install-worker.sh
  └── 2-install-control-plane.sh


values/
  ├── argo-events.yaml
  ├── ...
  ├── ...
```

---

## 🛠️ Installation Steps

### 1. Bootstrap RKE2

```bash
# Control planes
mkdir -p /etc/rancher/rke2/
echo "token: TBD
tls-san:
  - rke2-api.tronic.sk
cni:
  - cilium
disable:
  - rke2-canal
  - rke2-kube-proxy
  - rke2-ingress-nginx
" > /etc/rancher/rke2/config.yaml
curl -sfL https://get.rke2.io | INSTALL_RKE2_METHOD='tar' sh -
systemctl enable rke2-server.service
systemctl start rke2-server.service

# Worker nodes
mkdir -p /etc/rancher/rke2/
echo "token: TBD
server: https://188.245.175.94:9345
" > /etc/rancher/rke2/config.yaml
curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="agent" INSTALL_RKE2_METHOD='tar' sh -
systemctl enable rke2-agent.service
systemctl start rke2-agent.service
```

### 2. Install ArgoCD

```bash
kubectl create ns argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm -n argocd upgrade --install argocd argo/argo-cd --version 8.1.2
```

### 3. Deploy App-of-Apps

Create a YAML file `argo.yaml` with initial setup:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:lukas-pastva/kubernetes.git
    path: charts/internal/app-of-apps
    targetRevision: main
    helm:
      valueFiles:
        - ../../applications.yaml
  destination:
    namespace: argocd
    name: in-cluster
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Apply it:

```bash
kubectl apply -f argo.yaml
```

---

## 🖥️ VM Resource Calculations

| Scenario                | Control Plane | Worker Nodes | Total VMs | Rancher Availability          |
|-------------------------|---------------|--------------|-----------|-------------------------------|
| Minimal (non-HA)        | `1`           | `1`          | **2 VMs** | ❌ Temporarily unavailable    |
| Minimal Rancher-HA      | `1`           | `2`          | **3 VMs** | ✅ Available during upgrades  |
| Recommended Full HA     | `3`           | `3`          | **6 VMs** | ✅ Fully HA                   |

---

## 🚨 Disable Rancher Fleet (Recommended)

We use ArgoCD exclusively for GitOps-driven application deployments.  
Disable Fleet after installing Rancher by setting:

```yaml
fleet:
  enabled: false
```

---

## ⚙️ Integration with `argo-app-manager`

**Purpose:**  
An automated GitOps tool that allows easy Helm app deployment via ArgoCD App-of-Apps.

**Scripts:**  
- `_install.sh` is triggered by the frontend app (`argo-app-manager`) to add apps directly to GitOps.
- This script automatically disables Fleet by ensuring all apps are managed via GitOps (ArgoCD).

---

## 📌 Best Practices

- **Single Source of Truth:** All configuration in Git.
- **Automated Sync:** Critical apps auto-sync, prune, self-heal.
- **Separation of Concerns:** Rancher for infrastructure, ArgoCD for apps.
- **Node Affinity:** Rancher UI runs on control-plane nodes.

---

## 🔄 Safe Upgrades

- Upgrading RKE2 with Rancher on the same cluster is safe.
- Rancher UI may experience minimal downtime during upgrades but auto-recovers.

---

## ✅ Recommended Rancher Helm Values (`values/rancher.yaml`)

```yaml
hostname: rancher.tronic.sk
bootstrapPassword: admin_password
replicas: 3

ingress:
  enabled: true
  ingressClassName: nginx

resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    cpu: 1000m
    memory: 2Gi

tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: Exists

fleet:
  enabled: false
```

---

## 🚀 Workflow for App Installation (via `argo-app-manager`)

When installing new apps via the UI:

1. User inputs app details in `argo-app-manager`.
2. `_install.sh` script:
   - Adds Helm chart to GitOps repo.
   - Updates `applications.yaml`.
   - Commits & pushes to Git.
3. ArgoCD auto-syncs the app from Git to Kubernetes.

---

## 📖 Next Steps

1. Migrate existing apps fully into ArgoCD.
2. Regularly test backup & restore processes via Rancher.
3. Regularly perform rolling cluster upgrades to ensure HA functionality.

This structured approach ensures scalable, secure, and efficient Kubernetes infrastructure managed entirely via GitOps.
