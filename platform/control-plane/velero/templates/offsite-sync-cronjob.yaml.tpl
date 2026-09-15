# =============================================================================
# PostgreSQL Barman yedeklerinin (base backup + WAL) küme-dışına
# senkronizasyonu — Faz 12j, code review #9'un çözümü. Bkz. 06-velero.sh
# `setup_postgres_offsite_sync()` (bu şablonu render edip her keşfedilen
# postgres backup bucket'ı için AYRI bir CronJob olarak uygular).
#
# NEDEN İKİ ADIMLI (indir → yükle), DOĞRUDAN bucket-to-bucket DEĞİL: S3
# API'si iki FARKLI sağlayıcı (Ceph RGW ↔ offsite S3) arasında sunucu
# tarafı DOĞRUDAN kopyalamayı desteklemez — bir istemcinin ikisiyle de
# konuşup veriyi ELDEN GEÇİRMESİ gerekir. `emptyDir` staging alanı olarak
# kullanılıyor (PVC DEĞİL) — WAL arşivi büyüyebilir, `sync` her çalıştığında
# yalnızca YENİ/DEĞİŞEN nesneleri indirip yükler (`aws s3 sync`, tam bir
# kopya DEĞİL) ama İLK çalıştırma TÜM geçmiş veriyi indirip yükleyeceği
# için node'un diskinde YETERLİ boş alan olmalı — operatör kendi WAL
# hacmine göre `emptyDir.sizeLimit`'i AYARLAMALIDIR (varsayılan burada
# sınırsızdır, bilinçli — küçük bir varsayılan İLK senkronda sessizce
# başarısız olabilirdi).
# =============================================================================
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${JOB_NAME}
  namespace: offsite-sync
  labels:
    platform.internal/managed-by: velero-bootstrap
    platform.internal/layer: control-plane
spec:
  schedule: "0 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        metadata:
          labels:
            platform.internal/managed-by: velero-bootstrap
        spec:
          restartPolicy: OnFailure
          containers:
            - name: sync
              image: amazon/aws-cli:2.17.62
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  echo "[offsite-sync] ${BUCKET_NAME}: Ceph RGW'den indiriliyor..."
                  AWS_ACCESS_KEY_ID="$SRC_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SRC_SECRET_KEY" \
                    aws --endpoint-url "http://rook-ceph-rgw-${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80" \
                    s3 sync "s3://${BUCKET_NAME}" /staging --no-progress
                  echo "[offsite-sync] ${BUCKET_NAME}: offsite hedefe yükleniyor..."
                  AWS_ACCESS_KEY_ID="$DST_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$DST_SECRET_KEY" \
                    aws --endpoint-url "${VELERO_OFFSITE_S3_URL}" --region "${VELERO_OFFSITE_S3_REGION}" \
                    s3 sync /staging "s3://${BUCKET_NAME}" --no-progress
                  echo "[offsite-sync] ${BUCKET_NAME}: tamamlandı."
              env:
                - {name: SRC_ACCESS_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: SRC_ACCESS_KEY}}}
                - {name: SRC_SECRET_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: SRC_SECRET_KEY}}}
                - {name: DST_ACCESS_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: DST_ACCESS_KEY}}}
                - {name: DST_SECRET_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: DST_SECRET_KEY}}}
              resources:
                requests: {cpu: 100m, memory: 256Mi}
                limits: {cpu: 500m, memory: 1Gi}
              volumeMounts:
                - {name: staging, mountPath: /staging}
          volumes:
            - name: staging
              emptyDir: {}
