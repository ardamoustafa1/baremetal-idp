# sync-wave 1 — LoadBalancer. Cilium'dan sonra, depolamadan önce.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: underlay-metallb
  namespace: argocd
  labels:
    platform.internal/layer: underlay
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${METALLB_HELM_REPO}"
      chart: metallb
      targetRevision: "${METALLB_CHART_VERSION}"
      helm:
        releaseName: metallb
        valueFiles:
          - $values/platform/underlay/metallb/values.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
---
# sync-wave 2 — Adres havuzu. CRD'ler hazır olmadan uygulanamaz.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: underlay-metallb-config
  namespace: argocd
  labels:
    platform.internal/layer: underlay
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: platform
  source:
    repoURL: "${PLATFORM_REPO_URL}"
    targetRevision: "${PLATFORM_REPO_REVISION}"
    path: platform/underlay/metallb/rendered
  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
