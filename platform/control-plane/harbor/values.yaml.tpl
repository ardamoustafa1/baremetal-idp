# =============================================================================
# Harbor — self-hosted konteyner registry
# ADR-0001 L4. Depolama backend'i Rook-Ceph RGW (S3).
#
# BU DOSYADA PAROLA YOKTUR. Tüm sırlar existingSecret ile gelir; secret'ları
# 01-underlay.sh, .env'den ve Rook'un ürettiği OBC secret'ından oluşturur.
# =============================================================================

expose:
  type: loadBalancer
  tls:
    # Faz 3'te Vault PKI + cert-manager ile TLS açılacak (ADR-0001 Karar 2.3).
    # O ana kadar Harbor küme içi ve Cilium politikasıyla kısıtlı.
    enabled: false
  loadBalancer:
    name: harbor
    # IP BELİRTİLMEDİ — MetalLB havuzdan atar. Sabit IP isteniyorsa:
    #   annotations:
    #     metallb.universe.tf/loadBalancerIPs: <ip>
    # ve o IP .env'e taşınır.
    ports:
      httpPort: 80
    annotations: {}
    sourceRanges: []

externalURL: "http://${HARBOR_HOSTNAME}"

# --- Yönetici parolası ------------------------------------------------------
# Chart'ın varsayılanı "Harbor12345"tir. existingSecret ile ezilir.
existingSecretAdminPassword: harbor-admin-password
existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD

# --- İmaj/chart depolama: Rook-Ceph RGW (S3) --------------------------------
persistence:
  enabled: true
  resourcePolicy: "keep"           # Helm uninstall PVC'leri silmesin
  imageChartStorage:
    disableredirect: true          # RGW presigned redirect'i istemci tarafında
                                   # sorun çıkarır; registry proxy'lesin.
    type: s3
    s3:
      # Bu iki alan script tarafından OBC ConfigMap'inden doldurulur.
      region: us-east-1            # RGW için anlamsız ama S3 SDK zorunlu kılıyor
      bucket: "${HARBOR_REGISTRY_BUCKET}"
      regionendpoint: "${HARBOR_S3_ENDPOINT}"
      secure: false                # RGW'de TLS Faz 3'te açılacak
      v4auth: true
      # Erişim anahtarları Git'te DEĞİL — Rook'un ürettiği OBC secret'ından
      # kopyalanan harbor-registry-s3 secret'ında.
      # !!! DOĞRULAMA GEREKLİ: bu alanın adı ve beklediği anahtar isimleri
      # chart sürümüne göre değişir. Kurulum öncesi:
      #   helm show values harbor/harbor --version ${HARBOR_CHART_VERSION} \
      #     | grep -A20 'imageChartStorage'
      existingSecret: harbor-registry-s3

  # Registry dışındaki bileşenler blok depolama kullanır
  persistentVolumeClaim:
    registry:
      storageClass: "ceph-block"
      size: 5Gi                    # s3 modunda kullanılmaz ama chart ister
    jobservice:
      jobLog:
        storageClass: "ceph-block"
        size: 5Gi
    database:
      storageClass: "ceph-block"
      size: 20Gi
    redis:
      storageClass: "ceph-block"
      size: 5Gi
    trivy:
      storageClass: "ceph-block"
      size: 10Gi                   # zafiyet veritabanı önbelleği

# --- Trivy: zafiyet taraması ------------------------------------------------
trivy:
  enabled: true
  # Push'ta otomatik tarama, proje oluşturulurken proje ayarı olarak gelir.
  # Faz 6'da tenant Harbor projeleri composition tarafından
  # auto_scan=true ile yaratılacak (conventions §5 "Harbor projesi").
  # Buradaki ayar Trivy servisinin kendisiyle ilgilidir:
  ignoreUnfixed: false             # Düzeltmesi olmayan CVE'ler de raporlansın
  insecure: false
  skipUpdate: false                # DB'yi otomatik güncelle
  offlineScan: false
  securityCheck: "vuln"
  timeout: 5m0s
  resources:
    requests: {cpu: 200m, memory: 512Mi}
    limits:   {cpu: 400m, memory: 1Gi}

core:
  replicas: 1                      # 3 node test topolojisi; üretimde 2
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {cpu: 200m, memory: 512Mi}

jobservice:
  replicas: 1
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {cpu: 200m, memory: 512Mi}

registry:
  replicas: 1
  registry:
    resources:
      requests: {cpu: 100m, memory: 256Mi}
      limits:   {cpu: 200m, memory: 512Mi}
  controller:
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits:   {cpu: 200m, memory: 256Mi}

portal:
  replicas: 1
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits:   {cpu: 100m, memory: 256Mi}

# --- Veritabanı -------------------------------------------------------------
database:
  # Faz 1'de chart'ın kendi PostgreSQL'i.
  # TEKNİK BORÇ: Faz 4'te CloudNativePG'ye taşınacak (PLATFORM_CONTEXT #2).
  type: internal
  internal:
    # Parola script tarafından harbor-database secret'ına yazılır
    existingSecret: harbor-database-password
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits:   {cpu: 400m, memory: 1Gi}

redis:
  type: internal
  internal:
    resources:
      requests: {cpu: 100m, memory: 128Mi}
      limits:   {cpu: 200m, memory: 256Mi}

# --- Kimlik doğrulama -------------------------------------------------------
# Faz 1: yerel admin. Faz 4: Keycloak OIDC (ADR-0001 L4 "hepsi Keycloak'a bağlanır").
# OIDC client konfigürasyonu Faz 4'te eklenecek.

metrics:
  enabled: true
  serviceMonitor:
    enabled: false                 # Faz 4

updateStrategy:
  type: RollingUpdate

logLevel: info
