apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: tenant-requests
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: '0'
spec:
  sourceRepos:
  - ${TENANT_REQUESTS_REPO_URL}
  destinations:
  - name: in-cluster
    namespace: tenant-requests
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
  - group: platform.internal
    kind: Tenant
  - group: platform.internal
    kind: PostgreSQLInstance
---
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-requests
  labels:
    platform.internal/managed-by: platform
  annotations:
    argocd.argoproj.io/sync-wave: '0'
