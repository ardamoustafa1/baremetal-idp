# =============================================================================
# sync-wave 4 — Tenant API composition'ları (XRD + Composition)
#
# NEDEN AYRI/GEÇ EKLENDİ: Faz 6, XRD+Composition'ı yazıp GERÇEK araçlarla
# (`kclvm_cli`, `crossplane render`, `chainsaw lint`) test etti ama HİÇBİR
# ArgoCD Application'a bağlamadı — bu, Faz 6/6b'nin farkına varılmamış bir
# boşluğuydu. Bu dosya o boşluğu kapatır ve BÖYLECE Faz 7'nin
# `compositions/postgresql/` composition'ını da aynı Application ile taşır.
#
# İçindeki dosyaların KENDİ sync-wave anotasyonu var (xrd.yaml: "0",
# composition.yaml: "1") — bu Application'ın DIŞ wave'i (4) yalnızca
# "crossplane + provider'lar (wave 1) hazır olduktan SONRA" garantisini
# verir; XRD/Composition ARASINDAKİ sıra iç anotasyonlarla sağlanır.
#
# Crossplane Provider/Function CRD'leri gibi, CompositeResourceDefinition
# ve Composition için de ArgoCD'nin varsayılan health check'i YOKTUR — bu
# ikisi basitçe "Healthy" sayılır (Provider/Function'daki gibi özel bir Lua
# health check burada YAZILMADI çünkü XRD/Composition'ın "hazır" olması,
# yalnızca Crossplane'in onu içeriden reconcile etmesi kadar basittir ve
# yanlış render'da zaten pipeline hatası — bir sonraki claim/XR'da görünür
# olur, wave ilerlemesini yanlış yönde YAVAŞLATMAZ).
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tenant-api-compositions
  namespace: argocd
  labels:
    platform.internal/layer: compositions
  annotations:
    argocd.argoproj.io/sync-wave: "4"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/compositions/tenant
      directory:
        recurse: false
        # examples/ ve tests/ BİLEREK dışarıda — bunlar kalıcı kaynak
        # değil, yalnızca doğrulama/örnek amaçlı (aynı desen: Faz 3'ün
        # cert-manager/resources ayrımı).
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/compositions/postgresql
      directory:
        recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
