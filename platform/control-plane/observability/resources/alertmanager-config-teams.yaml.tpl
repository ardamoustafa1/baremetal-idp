# =============================================================================
# Alertmanager routing — Microsoft Teams (msteams_configs, Alertmanager ≥0.27)
# Slack varyantıyla AYNI routing mantığı, farklı receiver tipi.
# =============================================================================
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-kube-prometheus-stack-alertmanager
  namespace: observability
  labels:
    platform.internal/managed-by: observability-bootstrap
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m

    route:
      receiver: default-teams
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      routes:
        - receiver: cert-expiry-teams
          matchers:
            - alertname=~"CertificateExpiring.*|CertificateAlreadyExpired"
          repeat_interval: 4h
          continue: false

    receivers:
      - name: default-teams
        msteams_configs:
          - webhook_url: "${TEAMS_WEBHOOK_URL}"
            send_resolved: true
            title: '{{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'

      - name: cert-expiry-teams
        msteams_configs:
          - webhook_url: "${TEAMS_WEBHOOK_URL}"
            send_resolved: true
            title: '{{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'
