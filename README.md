# kubernetes
My OpenSource solution for GitOps Argo stack
 
### Install ArgoCD
```sh
kubectl create ns argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm -n argocd upgrade --install argocd argo/argo-cd --version 8.1.1
kubectl apply -f argo.yaml

# 1. Get Argo Initial secret and delete it from k8s secrets
# 2. Get into ArgoCD and insert the SSH key for the GitOps repo
# 3. Apply below YAML
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    targetRevision: 8.1.1
    chart: argo-cd
    helm:
      valuesObject:
        controller:
          resources:
            limits:
              memory: 1000Mi
            requests:
              cpu: 100m
              memory: 300Mi
        dex:
          enabled: false
          resources:
            limits:
              memory: 128Mi
            requests:
              cpu: 10m
              memory: 50Mi
        redis:
          resources:
            limits:
              memory: 128Mi
            requests:
              cpu: 30m
              memory: 50Mi
        server:
          ingress:
            enabled: true
            hostname: argocd.tronic.sk
            https: false
          resources:
            limits:
              memory: 200Mi
            requests:
              cpu: 40m
              memory: 128Mi
        repoServer:
          resources:
            limits:
              memory: 800Mi
            requests:
              cpu: 100m
              memory: 250Mi
        applicationSet:
          resources:
            limits:
              memory: 128Mi
            requests:
              cpu: 40m
              memory: 128Mi
        notifications:
          resources:
            limits:
              memory: 128Mi
            requests:
              cpu: 50m
              memory: 128Mi
        configs:
          params:
            server.insecure: true
          cm:
            exec.enabled: true
        extraObjects:
          - apiVersion: argoproj.io/v1alpha1
            kind: AppProject
            metadata:
              name: default
              namespace: argocd
            spec:
              clusterResourceWhitelist:
              - group: '*'
                kind: '*'
              description: default project
              destinations:
              - namespace: '*'
                server: '*'
              orphanedResources:
                warn: true
              sourceRepos:
              - '*'
          - apiVersion: argoproj.io/v1alpha1
            kind: Application
            metadata:
              name: app-of-apps
              namespace: argocd
            spec:
              project: default
              source:
                repoURL: git@github.com:lukas-pastva/kubernetes.git
                path: charts/app-of-apps
                targetRevision: main
                helm:
                  valueFiles:
                  - ../../applications.yaml
              destination:
                namespace: argocd
                name: in-cluster
  destination:
    server: "https://kubernetes.default.svc"
    namespace: argocd
  syncPolicy:
    automated:
       prune: true
       selfHeal: true
```
