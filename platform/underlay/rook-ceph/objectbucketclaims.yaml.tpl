# =============================================================================
# ObjectBucketClaim'ler
#
# Her OBC şunları üretir:
#   - Secret  <obc-adı>  : AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
#   - ConfigMap <obc-adı>: BUCKET_NAME / BUCKET_HOST / BUCKET_PORT
# Kimlik bilgileri Rook tarafından üretilir; Git'te DURMAZ.
# =============================================================================

# --- backup-bucket: Velero'nun yedek hedefi (Faz 9) -------------------------
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: backup-bucket
  namespace: rook-ceph
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
  annotations:
    platform.internal/description: >-
      Velero yedek hedefi. Faz 9'da BackupStorageLocation bu bucket'ı gösterir.
spec:
  bucketName: backup-bucket        # sabit ad — generateBucketName DEĞİL,
                                   # Velero konfigürasyonu deterministik olmalı
  storageClassName: ceph-bucket
---
# --- harbor-registry: Harbor'un imaj katmanlarını tuttuğu bucket ------------
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${HARBOR_REGISTRY_BUCKET}
  namespace: rook-ceph
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
  annotations:
    platform.internal/description: Harbor registry S3 backend (ADR-0001 L4).
spec:
  bucketName: ${HARBOR_REGISTRY_BUCKET}
  storageClassName: ceph-bucket
