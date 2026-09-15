apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: tenant-requests
  namespace: argocd
  labels:
    platform.internal/layer: tenant-requests
  annotations:
    argocd.argoproj.io/sync-wave: '1'
spec:
  goTemplate: true
  goTemplateOptions:
  - missingkey=error
  generators:
  - git:
      repoURL: ${TENANT_REQUESTS_REPO_URL}
      revision: main
      files:
      - path: tenants/*.yaml
      - path: postgresql/*.yaml
      - path: clusters/*/tenants/*.yaml
      - path: clusters/*/postgresql/*.yaml
      - path: tenants/*.yml
      - path: postgresql/*.yml
      - path: clusters/*/tenants/*.yml
      - path: clusters/*/postgresql/*.yml
      requeueAfterSeconds: 60
  template:
    metadata:
      name: claim-{{ if hasPrefix "clusters/" .path.path }}{{ index .path.segments 1 }}-{{ end }}{{ lower .kind }}-{{ .metadata.name }}
      labels:
        platform.internal/managed-by: applicationset
        platform.internal/claim-kind: '{{ lower .kind }}'
      annotations:
        platform.internal/source-path: '{{ .path.path }}/{{ .path.filename }}'
      finalizers:
      - resources-finalizer.argocd.argoproj.io
    spec:
      project: tenant-requests
      source:
        repoURL: ${TENANT_REQUESTS_REPO_URL}
        targetRevision: main
        path: '{{ .path.path }}'
        directory:
          include: '{{ .path.filename }}'
      destination:
        name: '{{ if hasPrefix "clusters/" .path.path }}{{ if eq (index .path.segments 1) "platform" }}in-cluster{{ else }}{{ index .path.segments 1 }}{{ end }}{{ else }}in-cluster{{ end }}'
        namespace: tenant-requests
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=false
        - ServerSideApply=true
        retry:
          limit: 5
          backoff:
            duration: 15s
            factor: 2
            maxDuration: 3m
  strategy:
    type: AllAtOnce
