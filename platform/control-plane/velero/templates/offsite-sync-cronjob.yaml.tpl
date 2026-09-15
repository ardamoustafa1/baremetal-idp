# =============================================================================
# PostgreSQL Barman yedeklerinin (base backup + WAL) küme-dışına
# senkronizasyonu — Faz 12j, code review #9'un çözümü. Bkz. 06-velero.sh
# `setup_postgres_offsite_sync()` (bu şablonu render edip her keşfedilen
# postgres backup bucket'ı için AYRI bir CronJob olarak uygular).
#
# DÜZELTME (Faz 12m, code review #5/#7): bu şablon ÖNCEDEN `amazon/aws-cli`
# ile İKİ AYRI adımda (Ceph RGW → `/staging` emptyDir → offsite S3)
# çalışıyordu. İKİ GERÇEK sorun vardı:
#   (5) `emptyDir` bir Job'un pod'una ÖZELDİR — HER GÜNKÜ CronJob çalıştırması
#       YENİ bir pod, dolayısıyla BOŞ bir `/staging` ile başlar. `aws s3 sync
#       kaynak /staging` bu yüzden HER GÜN TÜM bucket'ı YENİDEN İNDİRİRDİ
#       (yerel "sync" karşılaştırması her zaman "hiçbir şey yok, HEPSİNİ
#       indir" sonucu verirdi) — büyük veritabanlarında node diskini
#       doldurup pod eviction'a yol açabilirdi, `emptyDir.sizeLimit` de
#       HİÇ YOKTU.
#   (7) Hedef bucket'ın (offsite tarafında) VAR OLDUĞUNU varsayıyordu —
#       hiçbir oluşturma/doğrulama adımı YOKTU.
#
# ÇÖZÜM: `rclone`'a geçildi — `rclone sync remote1:bucket remote2:bucket`
# İKİ UZAK (remote) uç nokta arasında DOĞRUDAN, STREAMİNG bir aktarım yapar
# (nesne nesne indirilip HEMEN yüklenir, TÜM veri kümesinin yerel bir
# kopyası HİÇBİR ZAMAN diskte OLUŞMAZ) — hem #5'i (yerel staging YOK,
# dolayısıyla "her gün baştan indirme" sorunu YAPISAL olarak ORTADAN
# KALKAR — rclone karşılaştırmayı İKİ UZAK LİSTELEME üzerinden yapar, YEREL
# DURUMA hiç ihtiyaç duymaz) HEM DE (rclone'un `--s3-no-check-bucket=false`
# varsayılanı + AŞAĞIDAKİ AÇIK `rclone mkdir` adımı ile) #7'yi (hedef
# bucket'ın VAR OLMASI/OLUŞTURULMASI) çözer. `emptyDir`/`/staging` TAMAMEN
# KALDIRILDI.
#
# DÜZELTME (code review #5, KRİTİK — bu turda keşfedildi): `rclone sync`
# hedefi KAYNAKLA BİREBİR EŞİTLER — kaynakta OLMAYAN her nesneyi hedeften
# SİLER (bkz. https://rclone.org/commands/rclone_sync/, "Deletes any
# files that exist in dest but not in src"). Bu, "bağımsız, offsite bir
# ikinci kopya" tasarımının TEMEL AMACINI (kaynak KAZAYLA silinirse
# offsite'ta GERİ DÖNÜŞ NOKTASI kalması) DOĞRUDAN İHLAL EDER: kaynak
# bucket YANLIŞLIKLA boşaltılırsa (silme, bucket'ın KENDİSİNİ SİLMEZ —
# `rclone lsd` erişim kontrolü BAŞARILI olmaya DEVAM EDER), BİR SONRAKİ
# günlük çalıştırma offsite'taki TÜM nesneleri de SİLER — "offsite yedek"
# artık kaynaktaki bir kazaya karşı HİÇBİR koruma SAĞLAMAZ, yalnızca onu
# GECİKMELİ olarak TEKRARLAR. ÇÖZÜM: `rclone sync` → `rclone copy` (yeni/
# değişen nesneleri kopyalar, hedefte kaynakta OLMAYAN nesnelere HİÇ
# DOKUNMAZ — bkz. https://rclone.org/commands/rclone_copy/, "Doesn't
# transfer files that are identical on source and destination... doesn't
# delete files from destination"). Offsite artık YALNIZCA BİRİKEN bir
# kopyadır (disk kullanımı zamanla ARTAR — bilinçli bir maliyet/güvenlik
# ödünleşimi, bkz. aşağıdaki "boş kaynak koruması" notu ve
# `velero/README.md`). AYRICA: kaynak bucket TAMAMEN BOŞKEN (0 nesne) ama
# hedefte ZATEN nesne VARSA, bu KENDİ BAŞINA şüpheli bir durumdur (WAL
# arşivleme BOZULMUŞ veya kaynak YANLIŞLIKLA boşaltılmış olabilir) — aşağıda
# `rclone size` ile AÇIKÇA kontrol edilip Job BAŞARISIZ sayılır (sessizce
# "kopyalanacak bir şey yok" diyip başarıyla ÇIKMAK yerine).
# =============================================================================
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ${JOB_NAME}
  namespace: offsite-sync
  labels:
    platform.internal/managed-by: velero-bootstrap
    platform.internal/layer: control-plane
spec:
  schedule: "0 4 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      # DÜZELTME (code review #5, "iş süresi sınırı"): büyük bir WAL arşivi
      # sonsuza kadar sürmesin — 2 saat sonra Job BAŞARISIZ SAYILIR
      # (bir sonraki gün tekrar dener, `concurrencyPolicy: Forbid` üst
      # üste binmeyi engeller).
      activeDeadlineSeconds: 7200
      template:
        metadata:
          labels:
            platform.internal/managed-by: velero-bootstrap
        spec:
          restartPolicy: OnFailure
          containers:
            - name: sync
              image: ${OFFSITE_SYNC_RCLONE_IMAGE}
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eu
                  export RCLONE_CONFIG_CEPH_TYPE=s3
                  export RCLONE_CONFIG_CEPH_PROVIDER=Ceph
                  export RCLONE_CONFIG_CEPH_ENV_AUTH=false
                  export RCLONE_CONFIG_CEPH_ACCESS_KEY_ID="$SRC_ACCESS_KEY"
                  export RCLONE_CONFIG_CEPH_SECRET_ACCESS_KEY="$SRC_SECRET_KEY"
                  export RCLONE_CONFIG_CEPH_ENDPOINT="http://rook-ceph-rgw-${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80"

                  export RCLONE_CONFIG_OFFSITE_TYPE=s3
                  export RCLONE_CONFIG_OFFSITE_PROVIDER=Other
                  export RCLONE_CONFIG_OFFSITE_ENV_AUTH=false
                  export RCLONE_CONFIG_OFFSITE_ACCESS_KEY_ID="$DST_ACCESS_KEY"
                  export RCLONE_CONFIG_OFFSITE_SECRET_ACCESS_KEY="$DST_SECRET_KEY"
                  export RCLONE_CONFIG_OFFSITE_ENDPOINT="${VELERO_OFFSITE_S3_URL}"
                  export RCLONE_CONFIG_OFFSITE_REGION="${VELERO_OFFSITE_S3_REGION}"

                  # --- Ön kontrol: KAYNAK bucket'a erişim (code review #7,
                  # "erişim testi") — burada başarısız olmak, sync'in
                  # ORTASINDA belirsiz bir hatayla karşılaşmaktan İYİDİR.
                  echo "[offsite-sync] ${BUCKET_NAME}: kaynak bucket'a erişim doğrulanıyor..."
                  rclone lsd "ceph:${BUCKET_NAME}" >/dev/null

                  # --- Hedef bucket YOKSA oluştur (code review #7, "hedef
                  # bucket hazırlığı") — idempotent: zaten varsa no-op.
                  echo "[offsite-sync] ${BUCKET_NAME}: hedef bucket hazırlanıyor..."
                  rclone mkdir "offsite:${BUCKET_NAME}"

                  # --- Boş-kaynak koruması (code review #5): kaynak bucket
                  # SIFIR nesne içeriyorsa AMA hedefte ZATEN nesne varsa, bu
                  # muhtemelen WAL arşivlemenin BOZULDUĞUNU veya kaynağın
                  # YANLIŞLIKLA boşaltıldığını gösterir — `rclone copy` bu
                  # durumda hedefe DOKUNMAZ (silme YAPMAZ, bkz. yukarıdaki
                  # başlık notu) ama YİNE DE bunu SESSİZCE "başarılı, 0 nesne
                  # kopyalandı" diye geçmek YANLIŞ bir güven verir — bu yüzden
                  # AÇIKÇA Job'u BAŞARISIZ SAYIP alarm üretiyoruz.
                  # NOT (dürüstçe işaretli): `rclone size --json`'ın
                  # `{"count":N,...}` biçimi rclone'un belgelenmiş, kararlı
                  # çıktı şemasıdır — ama bu ortamda GERÇEK bir rclone
                  # binary'sine karşı CANLI DOĞRULANMADI (bu sandbox'ta
                  # rclone kurulu değil). İlk gerçek çalıştırmada
                  # doğrulanmalı.
                  src_count="$(rclone size "ceph:${BUCKET_NAME}" --json | grep -o '"count":[0-9]*' | cut -d: -f2)"
                  dst_count="$(rclone size "offsite:${BUCKET_NAME}" --json | grep -o '"count":[0-9]*' | cut -d: -f2)"
                  echo "[offsite-sync] ${BUCKET_NAME}: kaynak nesne sayısı=${src_count:-0}, hedef nesne sayısı=${dst_count:-0}"
                  if [ "${src_count:-0}" -eq 0 ] && [ "${dst_count:-0}" -gt 0 ]; then
                    echo "[offsite-sync] HATA: ${BUCKET_NAME} kaynağı BOŞ (0 nesne) ama offsite hedefte ${dst_count} nesne VAR — WAL arşivleme bozulmuş veya kaynak yanlışlıkla boşaltılmış olabilir. Kopyalama İPTAL, elle inceleyin." >&2
                    exit 1
                  fi

                  # --- Doğrudan uzaktan-uzağa KOPYALAMA (SENKRON DEĞİL —
                  # code review #5, yukarıdaki başlık notuna bakın) — YEREL
                  # staging YOK. `rclone copy`, kaynakta ARTIK OLMAYAN
                  # nesnelere hedefte HİÇ DOKUNMAZ (silme YAPMAZ) — offsite
                  # yalnızca BİRİKİR, kaynaktaki kazara bir silme offsite'a
                  # ASLA YAYILMAZ. --checksum: değişen içerik boyut+mtime
                  # yerine GERÇEK checksum ile tespit edilir (Barman'ın WAL
                  # dosyaları için daha güvenilir — mtime'lar RGW'nin KENDİ
                  # üretim zamanına göre değişebilir).
                  echo "[offsite-sync] ${BUCKET_NAME}: Ceph RGW → offsite doğrudan kopyalama (yalnızca EKLEME, SİLME YOK)..."
                  rclone copy "ceph:${BUCKET_NAME}" "offsite:${BUCKET_NAME}" --checksum --stats-one-line -v

                  # --- Başarı kapısı (code review #9'un "ilk gerçek
                  # aktarımın başarı kapısı" talebiyle AYNI ruhta): kopyalama
                  # sonrası kaynaktaki HER nesnenin hedefte GERÇEKTEN VAR
                  # olduğunu BAĞIMSIZ doğrular — yalnızca `rclone copy`'nin
                  # exit code'una GÜVENMEK yerine. `--one-way`: yalnızca
                  # kaynak→hedef eksiklikleri kontrol eder (hedefte kaynakta
                  # OLMAYAN eski nesnelerin varlığı — `copy`'nin BEKLENEN,
                  # BİRİKEN davranışı — bir HATA SAYILMAZ).
                  echo "[offsite-sync] ${BUCKET_NAME}: kopyalama sonrası doğrulama (rclone check)..."
                  rclone check "ceph:${BUCKET_NAME}" "offsite:${BUCKET_NAME}" --one-way
                  echo "[offsite-sync] ${BUCKET_NAME}: tamamlandı ve doğrulandı."
              env:
                - {name: SRC_ACCESS_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: SRC_ACCESS_KEY}}}
                - {name: SRC_SECRET_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: SRC_SECRET_KEY}}}
                - {name: DST_ACCESS_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: DST_ACCESS_KEY}}}
                - {name: DST_SECRET_KEY, valueFrom: {secretKeyRef: {name: "${JOB_NAME}-creds", key: DST_SECRET_KEY}}}
              resources:
                requests: {cpu: 100m, memory: 256Mi}
                limits: {cpu: 1, memory: 1Gi, ephemeral-storage: 2Gi}
