# =============================================================================
# Blok depolama (RBD) — ceph-block StorageClass'ın arkasındaki havuz
# =============================================================================
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: platform-blockpool
  namespace: rook-ceph
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
spec:
  failureDomain: host            # 3 node → host bazlı dağıtım
  replicated:
    size: ${CEPH_POOL_REPLICA_SIZE}
    # min_size: kaç replika ayaktayken yazmaya devam edilir.
    # 3/2 → bir node kaybında küme YAZILABİLİR kalır.
    # 3/1 YAPMAYIN: split-brain'de veri kaybı riski.
    requireSafeReplicaSize: true
    replicasPerFailureDomain: 1
  parameters:
    min_size: "${CEPH_POOL_MIN_REPLICA_SIZE}"
  # Havuz boyutu uyarı eşiği; kapasite planlaması Faz 1 sonunda yapılacak
  quotas: {}
