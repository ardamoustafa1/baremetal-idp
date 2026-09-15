# =============================================================================
# Tempo — trace depolama, Rook-Ceph RGW/S3 backend (Loki ile AYNI desen)
# =============================================================================

tempo:
  storage:
    trace:
      backend: s3
      s3:
        endpoint: rook-ceph-rgw-${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80
        bucket: tempo-storage
        insecure: true
        forcepathstyle: true
        access_key: "${TEMPO_S3_ACCESS_KEY}"
        secret_key: "${TEMPO_S3_SECRET_KEY}"

  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits:   {cpu: 500m, memory: 1Gi}

persistence:
  enabled: true
  storageClassName: ceph-block
  size: 10Gi

serviceMonitor:
  enabled: true
  labels:
    release: kube-prometheus-stack

# Hangi ingest protokolleri açık — OTLP (uygulamalardan) + Zipkin (uyumluluk)
traces:
  otlp:
    grpc:
      enabled: true
    http:
      enabled: true
  zipkin:
    enabled: true
  jaeger:
    thriftHttp:
      enabled: false   # kullanılmıyor, saldırı yüzeyini daraltır
