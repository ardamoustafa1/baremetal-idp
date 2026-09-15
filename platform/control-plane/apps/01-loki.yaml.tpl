# =============================================================================
# sync-wave 1 — Loki (log depolama, Rook-Ceph RGW/S3 backend)
#
# !!! OTOMATİK SYNC KASITLI OLARAK KAPALI (syncPolicy.automated YOK) !!!
# AYNI GEREKÇE: 00-underlay.yaml.tpl (underlay-root) — bu chart'ın
# values.yaml.tpl'i `${LOKI_S3_ACCESS_KEY}`/`${LOKI_S3_SECRET_KEY}`
# İÇERİR (Rook OBC'nin ürettiği S3 kimlik bilgileri). Bu değerler CLUSTER'A
# ÖZGÜDÜR ve Git'e ASLA yazılmaz — 05-observability.sh bunları Rook OBC
# Secret'ından (namespace: rook-ceph) okuyup envsubst ile YEREL bir
# `rendered/` dosyasına yazar ve `helm upgrade --install` ile DOĞRUDAN
# uygular. Bu Application, ArgoCD'nin bu kurulumu SONRADAN DEVRALMASI
# (adoption) içindir — devralma prosedürü tamamlanmadan automated sync
# AÇILIRSA, ArgoCD git'teki ÇÖZÜLMEMİŞ ${VAR} placeholder'ını uygulamaya
# çalışır ve mevcut, çalışan S3 kimlik bilgilerinin üzerine YANLIŞ/boş
# değer yazar (Harbor/underlay-root ile BİREBİR aynı risk).
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
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
    - repoURL: "${LOKI_HELM_REPO}"
      chart: loki
      targetRevision: "${LOKI_CHART_VERSION}"
      helm:
        releaseName: loki
        valueFiles:
          - $values/platform/control-plane/observability/loki/values.yaml.tpl
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
