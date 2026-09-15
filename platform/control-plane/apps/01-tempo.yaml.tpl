# =============================================================================
# sync-wave 1 — Tempo (trace depolama, Rook-Ceph RGW/S3 backend)
#
# !!! OTOMATİK SYNC KASITLI OLARAK KAPALI — 01-loki.yaml.tpl İLE BİREBİR AYNI
# GEREKÇE (S3 kimlik bilgileri ${TEMPO_S3_ACCESS_KEY}/${TEMPO_S3_SECRET_KEY}
# Git'e YAZILMAZ; 05-observability.sh yerel render + helm upgrade yapar,
# bu Application yalnızca SONRADAN devralma içindir). !!!
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tempo
  namespace: argocd
  labels:
    platform.internal/layer: observability
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${TEMPO_HELM_REPO}"
      chart: tempo
      targetRevision: "${TEMPO_CHART_VERSION}"
      helm:
        releaseName: tempo
        valueFiles:
          - $values/platform/control-plane/observability/tempo/values.yaml.tpl
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    # automated: KASITLI OLARAK YOK — yukarıdaki uyarıya bakın.
