# =============================================================================
# Tempo — trace depolama, Rook-Ceph RGW/S3 backend (Loki ile AYNI desen)
#
# DÜZELTME (code review #12) — Loki/values.yaml.tpl İLE AYNI düzeltme:
# S3 kimlik bilgileri (access_key/secret_key) ÖNCEDEN BU DOSYADA
# ${TEMPO_S3_ACCESS_KEY}/${TEMPO_S3_SECRET_KEY} olarak DOĞRUDAN
# gömülüydü — Velero için ZATEN çözülen "ArgoCD ham .tpl'i git'ten
# OLDUĞU GİBİ okur" riskiyle AYNI sınıf, ama burada SIR MATERYALİ İÇİN
# daha ciddi bir hâli. Artık `access_key`/`secret_key` BOŞ bırakılıp
# `tempo.extraEnv` ile `tempo-s3-credentials` Secret'ı (05-observability.sh
# `install_tempo()`, Rook OBC'den kopyalanır) AWS_ACCESS_KEY_ID/
# AWS_SECRET_ACCESS_KEY ortam değişkenleri ÜZERİNDEN referans alınıyor —
# Tempo'nun S3 istemcisi de (Loki ile AYNI, AWS SDK uyumlu) bu alanlar
# boşken standart kimlik bilgisi zincirine (env değişkenleri) düşer. Dosya
# artık HİÇBİR SIR İÇERMİYOR — güvenle render edilip commit edilebilir.
#
# DÜZELTME (code review #3, KRİTİK): `extraEnv` ÖNCEDEN KÖK SEVİYEDE
# tanımlıydı — önceki komentteki "CANLI doğrulanmadı" itirafı DOĞRU
# çıktı: kullanıcının GERÇEK `helm template` render'ı, grafana/tempo
# chart'ının kök seviyedeki `extraEnv`'i OKUMADIĞINI (StatefulSet'in
# `tempo` container'ında `env: null`) kanıtladı — doğru alan
# `tempo.extraEnv`'dir (aşağıya, `tempo:` bloğunun İÇİNE taşındı). Bu
# turda `helm template tempo grafana/tempo --version 1.10.3 -f
# <bu-dosya>` ile CANLI doğrulandı: `tempo.extraEnv` StatefulSet'in
# `tempo` container'ının `env` alanında GERÇEKTEN görünüyor.
# =============================================================================

tempo:
  extraEnv:
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef: {name: tempo-s3-credentials, key: AWS_ACCESS_KEY_ID}
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef: {name: tempo-s3-credentials, key: AWS_SECRET_ACCESS_KEY}
  storage:
    trace:
      backend: s3
      s3:
        endpoint: rook-ceph-rgw-${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80
        bucket: tempo-storage
        insecure: true
        forcepathstyle: true
        # access_key/secret_key BİLİNÇLİ OLARAK BOŞ/TANIMSIZ — yukarıdaki
        # `extraEnv`'e bakın.

  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits:   {cpu: 500m, memory: 1Gi}

persistence:
  enabled: true
  storageClassName: ceph-block
  size: 10Gi

serviceMonitor:
  enabled: true
  labels:
    release: kube-prometheus-stack

# Hangi ingest protokolleri açık — OTLP (uygulamalardan) + Zipkin (uyumluluk)
traces:
  otlp:
    grpc:
      enabled: true
    http:
      enabled: true
  zipkin:
    enabled: true
  jaeger:
    thriftHttp:
      enabled: false   # kullanılmıyor, saldırı yüzeyini daraltır
