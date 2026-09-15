# =============================================================================
# Alertmanager routing — Slack (native slack_configs, Alertmanager ≥0.27)
#
# ${SLACK_WEBHOOK_URL} yalnızca 05-observability.sh'in envsubst'üyle
# doldurulur, sonucun kendisi bir Secret'a konur ve DİSKE render edilmiş
# hali `.gitignore`'dadır — webhook URL'i Git'e asla düz metin GİRMEZ.
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
      slack_api_url: "${SLACK_WEBHOOK_URL}"

    route:
      receiver: default-slack
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      routes:
        - receiver: cert-expiry-slack
          matchers:
            - alertname=~"CertificateExpiring.*|CertificateAlreadyExpired"
          repeat_interval: 4h
          continue: false

    receivers:
      - name: default-slack
        slack_configs:
          - channel: "#platform-alerts"
            send_resolved: true
            title: '{{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'

      - name: cert-expiry-slack
        slack_configs:
          - channel: "#platform-cert-expiry"
            send_resolved: true
            color: '{{ if eq .CommonLabels.severity "critical" }}danger{{ else }}warning{{ end }}'
            title: '{{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'
