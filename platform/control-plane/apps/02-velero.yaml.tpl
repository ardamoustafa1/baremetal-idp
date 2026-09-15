# =============================================================================
# sync-wave 2 — Velero (K8s obje/PV yedekleme, Ceph RGW birincil hedef)
#
# !!! OTOMATİK SYNC KASITLI OLARAK KAPALI (syncPolicy.automated YOK) !!!
# AYNI GEREKÇE: 01-loki.yaml.tpl — bu chart'ın values.yaml.tpl'i
# `velero-credentials` Secret'ını (Rook OBC'nin ürettiği S3 kimlik bilgileri,
# isteğe bağlı offsite profili DAHİL) REFERANS ALIR. Bu değerler CLUSTER'A
# ÖZGÜDÜR ve Git'e ASLA yazılmaz — `06-velero.sh` bunları okuyup Secret'ı
# doğrudan `kubectl apply` ile oluşturur ve `helm upgrade --install`'ı
# DOĞRUDAN çalıştırır. Bu Application, ArgoCD'nin bu kurulumu SONRADAN
# DEVRALMASI (adoption) içindir.
#
# DÜZELTME (Faz 12h, code review #11): bu Application ÖNCEDEN HİÇ YOKTU —
# `platform/control-plane/velero/` boştu, README "⬜ Sıradaki" işaretliydi.
# `compositions/`'ların kendisi Velero'ya DOĞRUDAN bağımlı değildir (Velero
# tenant kaynaklarını DIŞARIDAN, ayrı bir mekanizmayla yedekler) ama
# `platform/underlay/storage-classes/storageclasses.yaml.tpl`'in
# `reclaimPolicy: Delete` kararı AÇIKÇA "Kurtarma yolu Velero'dur" diyor —
# Velero kurulu OLMADAN bu karar GEÇERSİZDİ.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  labels:
    platform.internal/layer: control-plane
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${VELERO_HELM_REPO}"
      chart: velero
      targetRevision: "${VELERO_CHART_VERSION}"
      helm:
        releaseName: velero
        valueFiles:
          - $values/platform/control-plane/velero/values.yaml.tpl
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/control-plane/velero/resources
      directory:
        recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    # automated: KASITLI OLARAK YOK — yukarıdaki uyarıya bakın.
