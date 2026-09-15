# AppProject — platform katmanlarının ArgoCD içindeki yetki sınırı.
# Faz 2'de ArgoCD kurulunca uygulanır (bkz. platform/bootstrap/02-control-plane.sh).
#
# NOT: Bu tek AppProject tüm platform katmanlarını (underlay → backstage)
# kapsar. sourceRepos listesi her yeni katman Helm repo'su eklendikçe büyür —
# tek bir dosyada tutulması, hangi chart kaynaklarının platforma güvenilir
# sayıldığını tek bakışta görünür kılar.
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform katmanları (underlay → backstage). Yalnızca platform ekibi.
  sourceRepos:
    - "${PLATFORM_REPO_URL}"
    - "${CILIUM_HELM_REPO}"
    - "${METALLB_HELM_REPO}"
    - "${ROOK_HELM_REPO}"
    - "${HARBOR_HELM_REPO}"
    - "${KEYCLOAK_HELM_REPO}"
    # --- Faz 2: control-plane ---
    - "${CROSSPLANE_HELM_REPO}"
    - "${KYVERNO_HELM_REPO}"
    - "${ESO_HELM_REPO}"
    # --- Faz 8: tenant-requests (ApplicationSet git generator kaynağı) ---
    - "${TENANT_REQUESTS_REPO_URL}"
    - "https://backstage.github.io/charts"
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "*"
  # Platform katmanı cluster-scoped kaynak yaratır (CRD, StorageClass, CCNP).
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
  orphanedResources:
    warn: true
