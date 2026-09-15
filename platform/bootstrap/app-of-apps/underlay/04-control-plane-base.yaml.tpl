# =============================================================================
# Harbor + Keycloak
#
# KATMAN NOTU: Bu ikisi ADR-0001'e göre L4 (control-plane) bileşenleridir,
# underlay değil. Faz 1 görev kapsamında birlikte kuruluyorlar; bu yüzden
# manifestleri control-plane/ altında durur ve root-underlay bunları
# sync-wave 6-7 ile çeker. Faz 4'te kendi root Application'larına taşınacak.
# =============================================================================

# sync-wave 6 — Keycloak ÖNCE: Harbor dahil her şey buna OIDC ile bağlanacak.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: control-plane-keycloak
  namespace: argocd
  labels:
    platform.internal/layer: control-plane
  annotations:
    argocd.argoproj.io/sync-wave: "6"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${KEYCLOAK_HELM_REPO}"
      chart: keycloak
      targetRevision: "${KEYCLOAK_CHART_VERSION}"
      helm:
        releaseName: keycloak
        valueFiles:
          - $values/platform/control-plane/keycloak/values.rendered.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: keycloak
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
---
# sync-wave 7 — Harbor. Rook RGW (wave 4) ve Keycloak (wave 6) hazır olmalı.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: control-plane-harbor
  namespace: argocd
  labels:
    platform.internal/layer: control-plane
  annotations:
    argocd.argoproj.io/sync-wave: "7"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${HARBOR_HELM_REPO}"
      chart: harbor
      targetRevision: "${HARBOR_CHART_VERSION}"
      helm:
        releaseName: harbor
        valueFiles:
          - $values/platform/control-plane/harbor/values.rendered.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: harbor
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
    retry:
      limit: 10
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 10m
