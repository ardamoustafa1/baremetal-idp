# =============================================================================
# Obje depolama (RGW, S3 API)
#
# Tüketiciler:
#   - Harbor registry backend (Faz 1)
#   - Velero yedek hedefi (Faz 9) — ADR-0001 Consequences #4
#   - Tenant bucket'ları (Faz 6, XBucket)
# =============================================================================
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: ${CEPH_OBJECTSTORE_NAME}
  namespace: rook-ceph
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
spec:
  metadataPool:
    failureDomain: host
    replicated:
      size: ${CEPH_POOL_REPLICA_SIZE}
      requireSafeReplicaSize: true
    parameters:
      min_size: "${CEPH_POOL_MIN_REPLICA_SIZE}"
  dataPool:
    failureDomain: host
    replicated:
      size: ${CEPH_POOL_REPLICA_SIZE}
      requireSafeReplicaSize: true
    parameters:
      min_size: "${CEPH_POOL_MIN_REPLICA_SIZE}"
  preservePoolsOnDelete: true
  gateway:
    port: 80
    # TLS Faz 3'te Vault PKI ile gelir (ADR-0001 Karar 2.3).
    # O zamana kadar RGW trafiği küme içi ve Cilium politikasıyla kısıtlı.
    securePort: 0
    instances: 2                   # 3 node → 2 RGW, tek node kaybına dayanır
    resources:
      requests: {cpu: "500m", memory: "1Gi"}
      limits:   {cpu: "1000m", memory: "2Gi"}
  healthCheck:
    startupProbe:
      disabled: false
    readinessProbe:
      disabled: false
---
# --- S3 StorageClass: ObjectBucketClaim'lerin kullanacağı sınıf --------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-bucket
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
provisioner: rook-ceph.ceph.rook.io/bucket
reclaimPolicy: Retain              # Bucket kazara silinmesin; imha bilinçli olsun
parameters:
  objectStoreName: ${CEPH_OBJECTSTORE_NAME}
  objectStoreNamespace: rook-ceph
