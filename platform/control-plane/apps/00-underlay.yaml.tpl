# =============================================================================
# sync-wave 0 — Underlay
#
# !!! OTOMATİK SYNC KASITLI OLARAK KAPALI (syncPolicy.automated YOK) !!!
#
# Faz 1'de underlay (Cilium/MetalLB/Rook/Keycloak/Harbor) `01-underlay.sh` ile
# ELLE (helm/kubectl doğrudan) kuruldu — ArgoCD henüz yoktu. Bu Application,
# ArgoCD'nin o kaynakları DEVRALMASI (adoption) içindir.
#
# Otomatik sync açılırsa ve bu Application'ın işaret ettiği .tpl dosyaları
# HENÜZ RENDER EDİLMEDEN (çıplak ${VAR} ile) senkronize edilirse, ArgoCD
# ÇALIŞAN doğru konfigürasyonun üzerine BOZUK yer tutucu değerler yazabilir
# (örn. Cilium'a literal "${K8S_API_SERVER_HOST}" string'i basılması).
#
# Devralma prosedürünü UYGULAMADAN bu Application'da automated sync AÇMAYIN:
#   platform/bootstrap/README.md → "Faz 1 → Faz 2 devralma"
#
# TEKNİK BORÇ (PLATFORM_CONTEXT.md #10): app-of-apps/underlay/*.yaml.tpl
# içindeki ${VAR} yer tutucuları, ArgoCD'nin doğrudan git'ten okuyabileceği
# somut değerlere render edilip commit edilmeden bu Application güvenle
# otomatik senkronize edilemez.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: underlay-root
  namespace: argocd
  labels:
    platform.internal/layer: underlay
  annotations:
    argocd.argoproj.io/sync-wave: "0"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: "${PLATFORM_REPO_URL}"
    targetRevision: "${PLATFORM_REPO_REVISION}"
    path: platform/bootstrap/app-of-apps/underlay
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
    # automated: KASITLI OLARAK YOK — yukarıdaki uyarıya bakın.
