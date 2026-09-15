# =============================================================================
# Loki — SingleBinary modu (3 node test topolojisi), Rook-Ceph RGW/S3 backend
#
# S3 kimlik bilgileri BURADA YOK — 05-observability.sh, Faz 1'in Harbor
# deseniyle (rook-ceph namespace'indeki OBC Secret'ını okuyup kopyalama)
# `loki-s3-credentials` Secret'ını üretir; bu dosya yalnızca Secret adını
# referans alır.
# =============================================================================

deploymentMode: SingleBinary   # 3 node'da SimpleScalable gereksiz karmaşıklık

loki:
  auth_enabled: false          # Küme-içi, Cilium NetworkPolicy ile korunuyor (Faz 3'ün Vault'una benzer bilinçli sınır)
  commonConfig:
    replication_factor: 1      # SingleBinary'de anlamsız (tek replika) — 9.5'te SimpleScalable'a geçilirse 3 yapılacak

  # DÜZELTME (Faz 12b, GERÇEK bir kind cluster'ında keşfedildi): chart
  # `schemaConfig` BOŞ BIRAKILDIĞINDA (varsayılan `{}`) chart'ın KENDİ
  # `templates/validate.yaml` doğrulaması KESİN olarak reddediyor ("a real
  # Loki install requires a proper schemaConfig") — bu alan da daha önce
  # HİÇ TANIMLANMAMIŞTI (loki/values.yaml.tpl'in canlı hiçbir Loki chart
  # kurulumunda çalıştırılmadığının ikinci bağımsız kanıtı). `tsdb` +
  # `object_store: s3` (yukarıdaki `storage.type: s3` ile TUTARLI) kullanan
  # standart bir tek-şema config eklendi.
  schemaConfig:
    configs:
      - from: "2024-01-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h

  storage:
    type: s3
    bucketNames:
      chunks: loki-storage
      ruler: loki-storage
      admin: loki-storage
    s3:
      endpoint: rook-ceph-rgw-${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80
      # NOT (bkz. compositions/postgresql/function.k'deki AYNI teknik borç):
      # RGW object store adı ("platform-store") burada da SABİT — Faz 1'in
      # .env.example varsayılanıyla KENETLİ.
      insecure: true            # RGW henüz TLS'siz (teknik borç, bkz. PLATFORM_CONTEXT)
      s3ForcePathStyle: true    # RGW path-style erişim ister (virtual-hosted DEĞİL)
      secretAccessKey: "${LOKI_S3_SECRET_KEY}"    # Helm --set-file/secret ile enjekte — bkz. script
      accessKeyId: "${LOKI_S3_ACCESS_KEY}"
    # NOT: secretAccessKey/accessKeyId'nin BURADA ${VAR} olarak durması
    # BİLİNÇLİDİR — bu dosya `helm template --set` ile DEĞİL, script'in
    # kendi envsubst'ü ile render edilir (bkz. 05-observability.sh), gerçek
    # helm install'da existingSecretName kullanılabilir sürüme geçilebilir
    # (Loki chart sürüm notuna bakılmalı).

# DÜZELTME (Faz 12b, GERÇEK bir kind cluster'ında keşfedildi): chart 6.16.0
# `deploymentMode: SingleBinary` KULLANILDIĞINDA BİLE `read`/`write`/
# `backend` (SimpleScalable modunun bileşenleri) için VARSAYILAN replika
# sayısı 3'TÜR — bu üçü SIFIRLANMADIĞI sürece chart'ın KENDİ
# `templates/validate.yaml` doğrulaması "more than zero replicas configured
# for both the single binary and simple scalable targets" hatasıyla
# KESİN olarak REDDEDİYOR. Bu değerler daha önce HİÇ SIFIRLANMAMIŞTI — bu
# values dosyası hiçbir gerçek Loki chart kurulumunda ÇALIŞTIRILMAMIŞTI.
read:
  replicas: 0
write:
  replicas: 0
backend:
  replicas: 0

singleBinary:
  replicas: 1
  persistence:
    storageClass: ceph-block
    size: 20Gi
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits:   {cpu: 500m, memory: 1Gi}

# Loki'nin kendi Grafana datasource ConfigMap'ini ÜRETMESİNİ SAĞLAMAZ —
# observability/values.yaml'daki additionalDataSources zaten statik olarak
# tanımlı (iki ayrı mekanizmayı karıştırmamak için).
monitoring:
  serviceMonitor:
    enabled: true
    labels:
      release: kube-prometheus-stack   # Prometheus'un serviceMonitorSelector'ıyla eşleşir

gateway:
  enabled: true   # nginx gateway — Grafana'nın datasource URL'i bunu hedefliyor

test:
  enabled: false
