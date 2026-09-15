# =============================================================================
# sync-wave 1 — Tempo (trace depolama, Rook-Ceph RGW/S3 backend)
#
# !!! OTOMATİK SYNC KASITLI OLARAK KAPALI — 01-loki.yaml.tpl İLE BİREBİR
# AYNI GEREKÇE (05-observability.sh `helm upgrade --install`'ı manuel
# çalıştırır; bu Application yalnızca SONRADAN devralma içindir). !!!
#
# DÜZELTME (code review #12) — 01-loki.yaml.tpl İLE AYNI düzeltme:
# `valueFiles` ÖNCEDEN ham `values.yaml.tpl`'e işaret ediyordu, o dosya
# GERÇEK S3 SIR değerlerini DOĞRUDAN İÇERİYORDU. values.yaml.tpl artık
# `extraEnv` + `tempo-s3-credentials` Secret referansı kullanıyor (HİÇBİR
# SIR İÇERMİYOR) — render edilip commit edilen `values.yaml`'a geçirildi.
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
          - $values/platform/control-plane/observability/tempo/values.yaml
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
