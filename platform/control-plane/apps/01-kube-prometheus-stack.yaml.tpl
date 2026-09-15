# =============================================================================
# sync-wave 1 — kube-prometheus-stack (Prometheus + Alertmanager + Grafana)
#
# Faz 9. Underlay (wave 0) ile PARALEL çalışabilir — Crossplane/Vault/
# cert-manager'a bağımlı DEĞİL, yalnızca Rook-Ceph'in `ceph-block`
# StorageClass'ına (Prometheus/Alertmanager/Grafana PVC'leri) ihtiyaç duyar.
#
# Bu Application'ın values.yaml'ında GERÇEK SIR YOK (Grafana admin parolası
# `existingSecret` ile dışarıdan bağlanıyor, Alertmanager routing config'i
# AYRI bir Secret'tan geliyor — bkz. resources/alertmanager-config-*.yaml.tpl)
# — bu yüzden, cert-manager Application'ıyla AYNI şekilde, otomatik sync
# GÜVENLİDİR (underlay-root/loki/tempo'nun aksine).
#
# ServiceMonitor/PrometheusRule CRD'lerini BU chart sağlar — cilium/
# values.yaml.tpl'deki (Faz 1) serviceMonitor.enabled bayrakları ve
# pki/cert-manager'ın ServiceMonitor'ı bu CRD'leri BEKLER (README'deki sıra
# notuna bakın: bu Application önce hazır olmalı).
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  labels:
    platform.internal/layer: observability
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${KUBE_PROMETHEUS_STACK_HELM_REPO}"
      chart: kube-prometheus-stack
      targetRevision: "${KUBE_PROMETHEUS_STACK_CHART_VERSION}"
      helm:
        releaseName: kube-prometheus-stack
        valueFiles:
          - $values/platform/control-plane/observability/values.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/control-plane/observability/resources
      directory:
        recurse: true
        # NOT: alertmanager-config-*.yaml.tpl ve objectbucketclaims.yaml
        # BİLEREK bu dizinin dışında YÖNETİLMİYOR demek YANLIŞ olur — OBC'ler
        # buradan gider (idempotent, sır İÇERMEZ); alertmanager-config-*.tpl
        # ise ${SLACK_WEBHOOK_URL}/${TEAMS_WEBHOOK_URL} İÇERDİĞİNDEN
        # ArgoCD'nin DEĞİL, 05-observability.sh'in render edip UYGULADIĞI
        # tek istisnadır (bkz. o script'in yorumları). Bu directory source,
        # ArgoCD'nin "kaynak taraması" sırasında bu iki .tpl dosyasını
        # okuyup HAM ${VAR} ile apply etmeye ÇALIŞMAMASI için exclude edilir:
        exclude: "alertmanager-config-*.yaml.tpl"
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
      - SkipDryRunOnMissingResource=true
