# =============================================================================
# StorageClass'lar
#
# NOT (conventions sapması): conventions.md §5 blok StorageClass kalıbını
# `ceph-block-<tier-sınıfı>` olarak tanımlıyor. Faz 1 görev tanımı ise adı
# açıkça `ceph-block` olarak istiyor. `ceph-block` kullanıldı ve bu sapma
# PLATFORM_CONTEXT.md "teknik borç" tablosuna kaydedildi (#1).
# =============================================================================

# --- Blok (RWO) — VARSAYILAN ------------------------------------------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: platform-blockpool
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
  csi.storage.k8s.io/fstype: ext4
# Delete: PVC silinince RBD image de silinir. Tenant verisi için doğru olan bu —
# aksi halde silinen tenant'ların imajları sessizce kapasite tüketir.
# Kurtarma yolu Velero'dur (Faz 9), Retain değil.
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
---
# --- Paylaşımlı (RWX) -------------------------------------------------------
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-filesystem
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: platform-fs
  pool: platform-fs-data0
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
