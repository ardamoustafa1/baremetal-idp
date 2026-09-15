# =============================================================================
# sync-wave 3 — cert-manager + Vault-backed ClusterIssuer'lar
#
# Vault'tan (wave 2) SONRA gelir çünkü ClusterIssuer'lar Vault'un kubernetes
# auth rolünü ve pki-int-* mount'larını bekler (bunlar 03-pki.sh tarafından
# imzalanmış, bu Application'ın YÖNETMEDİĞİ bir ön koşuldur — Vault'un
# kendisi bir Helm chart'la "kurulur" ama PKI/auth KONFİGÜRASYONU imperatif
# `vault` CLI çağrılarıyla yapılır, bkz. platform/pki/README.md).
#
# ClusterIssuer'lar Vault konfigürasyonu tamamlanana kadar `Ready=False`
# kalır — bu BEKLENEN bir ara durumdur, sync hatası değildir.
#
# ServiceMonitor CRD'si (monitoring.coreos.com/v1, Faz 4) henüz yoksa
# `SkipDryRunOnMissingResource=true` bu kaynağı sync'i bozmadan atlar.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
  labels:
    platform.internal/layer: pki
  annotations:
    argocd.argoproj.io/sync-wave: "3"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "https://charts.jetstack.io"
      chart: cert-manager
      targetRevision: "v1.16.2"  # versions.env: CERT_MANAGER_CHART_VERSION
      helm:
        releaseName: cert-manager
        valueFiles:
          - $values/platform/pki/cert-manager/values.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/pki/cert-manager/resources
      directory:
        recurse: true
        # NOT: values.yaml (Helm values dosyası) ve test-certificate.yaml.tpl
        # (kalıcı olmayan, 03-pki.sh'in verify_certificate() adımında geçici
        # uygulanan test kaynağı) BİLEREK bu dizinin DIŞINDA tutuluyor —
        # `resources/` yalnızca gerçek, kalıcı K8s manifestleri içerir
        # (Faz 2'nin crossplane/resources/ deseniyle birebir aynı).
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true   # servicemonitor.yaml → CRD Faz 4'te gelecek
