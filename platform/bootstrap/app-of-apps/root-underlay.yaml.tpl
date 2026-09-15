# =============================================================================
# ROOT APPLICATION — "App of Apps"
#
# !!! BU DOSYA FAZ 1'DE UYGULANMAZ !!!
# ArgoCD Faz 2'de kurulur. Bu manifest şimdiden yazılıyor ki Faz 1'de elle
# kurulan bileşenler, Faz 2'de ArgoCD tarafından DEVRALINABİLSİN.
#
# Devralma (adoption) notu — bu gerçek bir sürtünme noktasıdır:
#   Faz 1'de `helm install` ile kurulan release'lerin Helm secret'ları vardır.
#   ArgoCD aynı kaynakları yönetmeye başladığında sahiplik çakışması olur.
#   Çözüm: her child Application'da ServerSideApply + FieldManager ayarı
#   (aşağıda) ve Faz 2'de `helm uninstall --keep-history=false` YAPILMADAN,
#   sadece ArgoCD'nin kaynakları adopte etmesi. Adım adım prosedür:
#   platform/bootstrap/README.md "Faz 1 → Faz 2 devralma".
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: underlay-root
  namespace: argocd
  labels:
    platform.internal/layer: underlay
    platform.internal/managed-by: argocd
  finalizers:
    # Root silinirse child'lar da silinsin — yetim Application bırakmaz
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  source:
    repoURL: "${PLATFORM_REPO_URL}"
    targetRevision: "${PLATFORM_REPO_REVISION}"
    path: platform/bootstrap/app-of-apps/underlay
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=false
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 15s
        factor: 2
        maxDuration: 5m
