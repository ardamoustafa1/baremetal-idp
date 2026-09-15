# =============================================================================
# Paylaşımlı depolama (CephFS) — RWX PVC'ler için
# conventions.md §5: StorageClass adı "ceph-filesystem"
# Faz 1 Definition of Done: "RWO+RWX PVC bağlanıyor" → RWX bunu gerektirir.
# =============================================================================
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: platform-fs
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
  dataPools:
    - name: data0
      failureDomain: host
      replicated:
        size: ${CEPH_POOL_REPLICA_SIZE}
        requireSafeReplicaSize: true
      parameters:
        min_size: "${CEPH_POOL_MIN_REPLICA_SIZE}"
  preserveFilesystemOnDelete: true   # Yanlışlıkla silmeye karşı koruma
  metadataServer:
    activeCount: 1
    activeStandby: true              # 3 node'da 1 aktif + 1 standby yeterli
    resources:
      requests: {cpu: "250m", memory: "1Gi"}
      limits:   {cpu: "500m", memory: "2Gi"}
