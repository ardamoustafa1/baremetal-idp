# =============================================================================
# Velero — Rook-Ceph RGW (birincil) backend, isteğe bağlı küme-dışı (ikincil)
# hedef. Faz 12h, code review #11/#12'nin çözümü.
#
# S3 kimlik bilgileri BURADA YOK — Loki/Tempo deseniyle AYNI (bkz.
# observability/loki/values.yaml.tpl'in başlık yorumu): `06-velero.sh`,
# `rook-ceph` namespace'indeki OBC Secret'ını okuyup `velero` namespace'inde
# bir Secret üretir; bu dosya yalnızca o Secret'ın adını/profil anahtarlarını
# referans alır. `${VELERO_OFFSITE_*}` bloğu YALNIZCA `VELERO_OFFSITE_ENABLED=
# true` ayarlandığında ANLAMLI olur (bkz. .env.example) — script bu durumda
# İKİNCİ bir profili AYNI Secret'a ekler.
#
# File-system backup uses explicit pod volume annotations. Native database
# backups remain separate; do not copy live database files as a consistent dump.
# Before release, verify every Bound PVC with tests/readiness/check-live.py.
# =============================================================================

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.10.1
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins

resources:
  requests: {cpu: 100m, memory: 128Mi}
  limits: {cpu: 500m, memory: 256Mi}

configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      credential:
        name: velero-credentials
        key: cloud
      config:
        region: default
        profile: default
        s3Url: "http://rook-ceph-rgw-${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80"
        s3ForcePathStyle: "true"
        insecureSkipTLSVerify: "true"   # RGW henüz TLS'siz (aynı teknik borç, bkz. PLATFORM_CONTEXT)
  volumeSnapshotLocation: []
  defaultVolumesToFsBackup: false
  uploaderType: kopia

# Opt in with backup.velero.io/backup-volumes on the workload's pod template.
# All tainted nodes must also be covered; hostPath is required by Velero FSB.
deployNodeAgent: true
nodeAgent:
  tolerations:
    - operator: Exists
  resources:
    requests: {cpu: 100m, memory: 128Mi}
    limits: {cpu: 1000m, memory: 1Gi}

credentials:
  useSecret: true
  existingSecret: velero-credentials
  existingSecretKey: cloud

schedules:
  # DÜZELTME (Faz 12h, code review #12): "kabul edilen veri kaybı" (RPO)
  # burada SOMUT hale getiriliyor — bkz. control-plane/velero/README.md
  # "RPO/RTO" bölümü. Günlük 03:00 UTC (docs/runbooks/disaster-recovery.md
  # §0'ın ZATEN belirttiği zamanlama ile AYNI — yeni bir karar İCAT
  # EDİLMEDİ, var olan tasarım burada GERÇEKTEN uygulandı).
  daily:
    schedule: "0 3 * * *"
    useOwnerReferencesInBackup: false
    template:
      snapshotVolumes: false
      defaultVolumesToFsBackup: false
      storageLocation: default
      ttl: "720h"   # 30 gün saklama
      includedNamespaces: ["*"]
      includeClusterResources: true
