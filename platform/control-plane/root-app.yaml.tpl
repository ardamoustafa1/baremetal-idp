# =============================================================================
# ROOT APPLICATION — Faz 2 App-of-Apps
#
# ArgoCD kurulduktan hemen sonra, elle (02-control-plane.sh içinde) uygulanan
# TEK manifest budur. Bundan sonraki her şey `platform/control-plane/apps/`
# dizinindeki child Application'lar üzerinden Git'ten gelir.
#
# Bu Application'ın KENDİSİ prune:true'dur — Application CR'ları ucuzdur,
# silinip yeniden yaratılabilir (asıl veri Crossplane/Ceph/Postgre gibi alt
# kaynaklardadır, onlar için prune kararları child Application'larda ayrı
# ayrı ve BİLİNÇLİ verilir; bkz. app-of-apps/underlay/*.yaml.tpl).
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-root
  namespace: argocd
  labels:
    platform.internal/managed-by: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: "${PLATFORM_REPO_URL}"
    targetRevision: "${PLATFORM_REPO_REVISION}"
    path: platform/control-plane/apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
