# =============================================================================
# sync-wave 1 — External Secrets Operator
#
# YALNIZCA OPERATOR. SecretStore/ClusterSecretStore burada YOK — Vault
# (Faz 3) hazır olmadan bağlanacak bir yer yok. ADR-0001 Karar 2.3.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: eso
  namespace: argocd
  labels:
    platform.internal/layer: control-plane
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    # NOT: repo/sürüm SOMUTLAŞTIRILDI (versions.env ile senkron tutun) — bkz.
    # 01-crossplane.yaml.tpl üstündeki gerekçe.
    - repoURL: "https://charts.external-secrets.io"
      chart: external-secrets
      targetRevision: "0.10.7"  # versions.env: ESO_CHART_VERSION
      helm:
        releaseName: external-secrets
        valueFiles:
          - $values/platform/control-plane/external-secrets/values.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: external-secrets
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
