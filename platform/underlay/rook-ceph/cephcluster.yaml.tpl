# =============================================================================
# CephCluster — 3 node'luk test topolojisi
#
# Sizing gerekçeleri için: platform/underlay/rook-ceph/README.md
#
# UYARI: ${CEPH_OSD_DEVICE_FILTER} ile eşleşen diskler ÜZERİNDEKİ VERİ SİLİNİR.
# Script, apply öncesi eşleşen cihazları gösterip onay ister.
# =============================================================================
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: platform-ceph
  namespace: rook-ceph
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
spec:
  cephVersion:
    image: quay.io/ceph/ceph:v18.2.4
    # 3 node'da 3 MON = her node'da bir MON. Bir node kaybında 2/3 quorum korunur.
    allowUnsupported: false

  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  continueUpgradeAfterChecksEvenIfNotHealthy: false

  mon:
    count: 3
    allowMultiplePerNode: false   # 3 fiziksel node var; aynı node'a 2 MON = sahte HA

  mgr:
    count: 2                      # aktif + standby
    allowMultiplePerNode: false
    modules:
      - name: rook
        enabled: true
      - name: pg_autoscaler
        enabled: true             # PG sayısını elle hesaplamaktan kurtarır

  dashboard:
    enabled: true
    ssl: false                    # TLS Faz 3'te Vault/cert-manager ile gelir
    # Dashboard'a erişim şimdilik port-forward ile; Gateway API arkasına
    # alınması Faz 3'te Keycloak OIDC ile birlikte yapılacak.

  network:
    provider: host
    connections:
      # Ceph'in kendi şifrelemesi. 3 node'luk test topolojisinde CPU maliyeti
      # kabul edilebilir; üretimde msgr2 encryption açık kalmalı.
      encryption:
        enabled: false            # Faz 4'te kapasite ölçüldükten sonra açılacak
      compression:
        enabled: false

  crashCollector:
    disable: false

  logCollector:
    enabled: true
    periodicity: daily
    maxLogSize: 500M

  # Node kaybında otomatik OSD çıkarma — 3 node'da TEHLİKELİ.
  # 1 node düşerse 2 kalır; otomatik yeniden dengeleme kalan 2 node'u doldurabilir.
  # Bu yüzden kapalı: operatör kararı verir.
  removeOSDsIfOutAndSafeToRemove: false

  storage:
    useAllNodes: true
    useAllDevices: false          # Kör disk tüketimi YASAK — filtre zorunlu
    deviceFilter: "${CEPH_OSD_DEVICE_FILTER}"
    config:
      osdsPerDevice: "1"

  # PDB: yeniden dengeleme sırasında aynı anda birden fazla OSD'nin
  # düşmesini engeller. 3 node'da bu, veri kaybı ile kesinti arasındaki fark.
  disruptionManagement:
    managePodBudgets: true
    osdMaintenanceTimeout: 30
    pgHealthCheckTimeout: 0

  resources:
    mgr:
      requests: {cpu: "250m", memory: "512Mi"}
      limits:   {cpu: "500m", memory: "1Gi"}
    mon:
      requests: {cpu: "250m", memory: "1Gi"}
      limits:   {cpu: "500m", memory: "2Gi"}
    osd:
      requests: {cpu: "500m", memory: "2Gi"}
      limits:   {cpu: "1000m", memory: "4Gi"}
    prepareosd:
      requests: {cpu: "250m", memory: "50Mi"}
    crashcollector:
      requests: {cpu: "50m", memory: "60Mi"}
      limits:   {cpu: "100m", memory: "128Mi"}
    logcollector:
      requests: {cpu: "50m", memory: "100Mi"}
      limits:   {cpu: "100m", memory: "256Mi"}
    cleanup:
      requests: {cpu: "250m", memory: "100Mi"}

  healthCheck:
    daemonHealth:
      mon:
        disabled: false
        interval: 45s
      osd:
        disabled: false
        interval: 60s
      status:
        disabled: false
        interval: 60s
    livenessProbe:
      mon:
        disabled: false
      osd:
        disabled: false
