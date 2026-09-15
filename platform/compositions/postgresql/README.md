# XPostgreSQLInstance — Self-servis CloudNativePG soyutlaması

Faz 7. ADR-0001 Karar 2.1 + Karar 2.4. Geliştirici bakış açısından:
[`docs/runbooks/request-postgres.md`](../../docs/runbooks/request-postgres.md).

---

## Ürettiği kaynaklar (10 + koşullu 1 = 11)

| # | Kaynak | Amaç |
|---|---|---|
| 1 | `ObjectBucketClaim` (Rook-Ceph) | Barman WAL/backup hedefi — bucket adı `<tenantRef>-<name>-backup` |
| 2 | `Certificate` (cert-manager, tenant'ın kendi Issuer'ından) | Postgres TLS — `<name>-{rw,ro,r}.<tenantRef>.svc.cluster.local` |
| 3 | `Cluster` (CloudNativePG) | Asıl Postgres instance'ı — `ceph-block` storage, Barman entegre |
| 4 | `ScheduledBackup` (CNPG native) | Günlük yedek — CronJob DEĞİL |
| 5 | `CiliumNetworkPolicy` | Tenant'ın default-deny'sinin ÜSTÜNE, yalnızca 5432'ye aynı-tenant izni |
| 6 | `ServiceMonitor` | postgres-exporter metrikleri — Faz 4'e kadar inert (Prometheus Operator CRD'si yok) |
| 7 | `SecretStore` (ESO, namespaced) | Vault KV backend, tenant başına |
| 8 | `PushSecret` (ESO) | CNPG'nin native `<name>-app` Secret'ını Vault'a yazar |
| 9 | `ExternalSecret` (ESO) | Vault'tan `<name>-connection` Secret'ını geri çeker |
| 10 | `ConfigMap` (Faz 8) | Backstage catalog-info — `../../backstage/README.md` |
| 11 | `PodDisruptionBudget` | **Yalnızca `highAvailability=true`** |

---

## `tenantRef` ne anlama geliyor (önemli tasarım kararı)

`tenantRef`, bir **Tenant claim adı değil** — doğrudan o tenant'ın **var
olan namespace adıdır** (örn. `tenant-acme-dev`). Neden: Crossplane
composition function'ları başka bir claim'in spec'ini okuyup ondan
namespace türetemez (cross-resource reference, bu fazın kapsamı dışında —
bkz. PLATFORM_CONTEXT.md teknik borcu). İsteyen kişi kendi tenant'ının
namespace adını `kubectl get xtenant`'tan kopyalar.

## Neden ExternalSecret, CNPG'nin Secret'ı zaten yeterliyken?

CNPG kendi `<name>-app` Secret'ını otomatik üretir ve o Secret zaten
doğru namespace'tedir — teoride başka hiçbir şeye gerek yok. Görev
açıkça bir `ExternalSecret` istediği için (ADR-0001 Karar 2.3'ün "tüm
secret'lar Vault'tan akar" ilkesini TUTARLI kılmak amacıyla), bu composition
CNPG'nin Secret'ını **Vault'a push edip geri çeker** (`PushSecret` →
`ExternalSecret`). Bu, gerçek bir round-trip'tir — dürüstçe belirtiyoruz:
CNPG'nin native Secret'ı zaten kullanılabilir durumdaydı, bu ek katman
platform standardını korumak içindir, teknik bir zorunluluk değil.

**Bu round-trip'in gerektirdiği Faz 3 eklentisi:** `kv/` KV v2 mount'u
(Faz 6'da "henüz enable edilmedi" denilmişti) ve yeni bir Vault
Kubernetes-auth rolü (`eso-tenant-secrets`, ESO'nun paylaşımlı controller
kimliğine bağlı, `kv/data/tenants/*` ile sınırlı) — `03-pki.sh`'e eklendi.

## Vault izolasyonu — Faz 6'nın PKI rolünü yeniden kullanır

Certificate, tenant'ın **kendi** `tenant-issuer`'ını kullanır — bu Issuer'ın
arkasındaki Vault PKI rolü zaten yalnızca `*.{tenantRef}.svc.cluster.local`
için sertifika üretebiliyordu (Faz 6b). Bu composition YENİ bir izolasyon
mekanizması İCAT ETMEDİ — var olanı doğrudan tüketti.

`kv/data/tenants/*` yolu ise TÜM tenant'lar arasında PAYLAŞILAN tek bir
ESO kimliğiyle erişiliyor (SA-bazlı izolasyon yok) — path prefix'i
(`tenants/<tenantRef>/...`) tek izolasyon sınırıdır. Bu, Faz 6'nın
tenant-özel Vault k8s-auth rolleri kadar sıkı bir izolasyon DEĞİLDİR;
bilinçli bir basitleştirme (bkz. PLATFORM_CONTEXT.md teknik borcu).

## Restore / PITR (Faz 12h, code review #12'nin çözümü)

Bu composition'ın ürettiği `Cluster` kaynağı zaten `backup.barmanObjectStore`
ile (§1'deki `backupBucket`, Ceph RGW) sürekli WAL archiving yapıyor —
gerçek kurtarma yolu Velero DEĞİL, CNPG'nin KENDİ `bootstrap.recovery`
mekanizmasıdır (bkz. `platform/control-plane/velero/README.md`'nin "Ne
yedekleniyor" tablosu).

**Prosedür (mevcut bir Cluster'ı, KENDİ backup'ından YENİ bir Cluster olarak
geri yüklemek — CNPG'nin resmi, desteklenen deseni):**

```bash
# 1. Mevcut Cluster'ın adını/namespace'ini ve backup bucket'ını doğrulayın:
kubectl -n <tenant-ns> get cluster <name> -o jsonpath='{.spec.backup.barmanObjectStore}'

# 2. YENİ bir Cluster manifesti yazın — externalClusters + bootstrap.recovery
#    ile AYNI bucket'a işaret eder (orijinal Cluster'ı DEĞİŞTİRMEZ, yanına
#    yeni bir Cluster açar — kanıtlanmadan orijinali silmeyin):
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <name>-restore-test
  namespace: <tenant-ns>
spec:
  instances: 1
  storage:
    size: <orijinaliyle AYNI>
    storageClass: ceph-block
  bootstrap:
    recovery:
      source: original
  externalClusters:
    - name: original
      barmanObjectStore:
        destinationPath: "s3://<tenantRef>-<name>-backup/"
        endpointURL: "http://rook-ceph-rgw-\${CEPH_OBJECTSTORE_NAME}.rook-ceph.svc.cluster.local:80"
        s3Credentials:
          accessKeyId: {name: "<name>-backup", key: AWS_ACCESS_KEY_ID}
          secretAccessKey: {name: "<name>-backup", key: AWS_SECRET_ACCESS_KEY}
EOF

# 3. Yeni Cluster'ın Ready olmasını ve verinin GERÇEKTEN geldiğini doğrulayın:
kubectl -n <tenant-ns> wait cluster/<name>-restore-test --for=condition=Ready --timeout=300s
kubectl -n <tenant-ns> exec <name>-restore-test-1 -- psql -U postgres -c "SELECT count(*) FROM <bilinen bir tablo>;"

# 4. Doğrulama SONRASI test Cluster'ını silin (kalıcı bırakmayın — çift kota tüketir):
kubectl -n <tenant-ns> delete cluster <name>-restore-test
```

**Dürüstlük notu:** bu prosedür CNPG'nin resmi, desteklenen `bootstrap.
recovery` mekanizmasına dayanır ve bu composition'ın ZATEN ürettiği
`barmanObjectStore` yapılandırmasıyla tutarlı olacak şekilde yazıldı — ama
bu görevde GERÇEK bir cluster'a karşı UÇTAN UCA ÇALIŞTIRILMADI (bkz.
`platform/control-plane/velero/README.md`'nin RPO/RTO tablosundaki "ÖLÇÜLMEDİ"
notu). İlk üretim kullanımından ÖNCE bir tenant'ta gerçekten denenmeli.

## Offsite'tan restore — CANLIYA GEÇMEDEN ÖNCE ZORUNLU (code review #9)

Yukarıdaki prosedür yalnızca BİRİNCİL kaynağı (Ceph RGW) test eder.
`rclone check` (offsite-sync'in KENDİ doğrulaması, bkz. `velero/README.md`)
YALNIZCA iki taraftaki NESNELERİN eşit olduğunu kanıtlar — PostgreSQL'in o
base backup + WAL zincirinden GERÇEKTEN AÇILABİLDİĞİNİ KANITLAMAZ. Ayrıca
günlük 04:00 aktarımı SÜREKLİ bir WAL koruması DEĞİLDİR — son başarılı
aktarımdan SONRA üretilen veri, tam bir küme kaybında KAYBEDİLEBİLİR (bkz.
aşağıdaki RPO notu). Bu ikisi CANLIYA GEÇMEDEN ÖNCE, GERÇEK bir kümede
(bu görevde YAPILAMADI — gerçek Ceph/offsite S3 yok) ayrı ayrı KANITLANMALI:

```bash
# 1. Ceph RGW'ye erişimi GEÇİCİ olarak KESİN (yalnızca test amaçlı — örn.
#    bir NetworkPolicy ile rook-ceph-rgw Service'ini test namespace'inden
#    izole edin, RGW'nin KENDİSİNİ DURDURMAYIN — diğer tenant'ları etkiler).

# 2. YUKARIDAKİ "Restore / PITR" prosedürünün AYNISINI, TEK farkla:
#    externalClusters.barmanObjectStore.endpointURL Ceph RGW YERİNE
#    GERÇEK offsite S3 endpoint'ine (VELERO_OFFSITE_S3_URL) işaret etmeli,
#    s3Credentials DE offsite kimlik bilgilerine (DST_ACCESS_KEY/
#    DST_SECRET_KEY, bkz. `<job-adı>-creds` Secret'ı, `offsite-sync`
#    namespace'i) işaret etmelidir — kaynak Ceph'ten DEĞİL, YALNIZCA
#    offsite'tan restore edildiğini KANITLAMAK için.

# 3. Kabul kriterleri (kullanıcının KENDİ talebi, code review #9):
#    a) Yeni Cluster Ready olur (Ceph RGW'ye HİÇ erişim OLMADAN).
#    b) PostgreSQL GERÇEKTEN açılır (yukarıdaki `psql` sorgusu ÇALIŞIR).
#    c) BEKLENEN kayıtlar bulunur (test öncesi bilinen bir satır sayısı/
#       değer ile karşılaştırılır — yalnızca "Cluster Ready" YETERLİ DEĞİL).
#    d) Belirli bir ZAMANA geri dönüş (PITR) çalışır:
#       `bootstrap.recovery.recoveryTarget.targetTime: "<ISO8601>"` ile
#       test edilmeli — yalnızca "en son" DEĞİL, GEÇMİŞTE bir ANA dönmek.
#    e) Veri kaybı (RPO) ve geri dönüş süresi (RTO) ÖLÇÜLÜR: test öncesi
#       bilinen bir yazma zaman damgası ile restore SONRASI en son GÖRÜNEN
#       kayıt arasındaki fark = GERÇEK RPO; adım 2'nin BAŞLANGICINDAN
#       Cluster Ready olana kadar geçen süre = GERÇEK RTO. Bu iki sayı
#       `velero/README.md`'nin RPO/RTO tablosundaki "ÖLÇÜLMEDİ" notunun
#       YERİNE GEÇMELİDİR.

# 4. Test SONRASI: test Cluster'ını silin, Ceph RGW erişimini GERİ AÇIN.
```

**Genel PVC içerikleri (Postgres DIŞI) için ayrı bir veri yedekleme yolu
HÂLÂ yok** — bkz. `PLATFORM_CONTEXT.md` teknik borç #42 (Faz 12m'de
işaretlendi, bu turda TEKRAR doğrulandı — henüz KAPATILMADI).

## Test etme

```bash
# 1. Saf KCL mantığı (Docker/cluster GEREKMİYOR)
kclvm_cli run function.k -D params='{"oxr": {"metadata":{"name":"orders-db"}, "spec": {...}}}'

# 2. function.k ↔ composition.yaml senkron kontrolü
./tests/verify-sync.sh

# 3. Gerçek crossplane render (Docker GEREKİR)
./tests/render-examples.sh
# Çıktı: platform/docs/examples-output/postgresql-{small,ha-large}.rendered.yaml

# 4. KABUL KRİTERİ: highAvailability=true + size=small → REDDEDİLMELİ
#    (Bu PR'da GERÇEK Docker+function-kcl ile doğrulandı, exit=1)

# 5. Uçtan uca (GERÇEK CLUSTER gerekir)
chainsaw test tests/e2e/
```

Bu PR'da 1-4 **fiilen çalıştırıldı ve doğru sonuç verdi** (bkz.
PLATFORM_CONTEXT.md Faz günlüğü); 5 yalnızca `chainsaw lint` +
`test --no-cluster` ile yapısal olarak doğrulandı.

## Provizyon öncesi kontrol listesi (code review #14)

`function.k`'nin `pgImage`'ı `_harborHostname` sabitine KENETLİDİR (KCL'in
shell ortam değişkenlerine erişimi YOK — bkz. `function.k`'deki
`_harborHostname` yorumu). İlk provizyondan (veya `PLATFORM_BASE_DOMAIN`
değiştikten) ÖNCE:

```bash
# 1. STATİK senkron kontrolü — function.k'nin _harborHostname'i GERÇEK
#    HARBOR_HOSTNAME (.env'den türetilir) ile eşleşiyor mu? Ağ erişimi
#    GEREKMEZ, CI'da HER PR'da çalışır.
bash tests/verify-harbor-image-config.sh

# 2. CANLI kontrol — her PostgreSQL sürümü (_pgImageTags) imajı GERÇEKTEN
#    Harbor'da mevcut mu, (COSIGN_PUBLIC_KEY verildiyse) imzalı mı?
#    GERÇEK bir Harbor'a ağ erişimi GEREKİR — CI'da ÇALIŞTIRILMAZ (bu
#    repo'nun sandbox'ında gerçek bir Harbor/cosign yok, bkz.
#    PLATFORM_CONTEXT.md). Provizyondan HEMEN önce operatör tarafından
#    elle çalıştırılmalı.
export HARBOR_HOSTNAME=harbor.<gerçek-domain>
export COSIGN_PUBLIC_KEY=/path/to/cosign.pub   # isteğe bağlı, imza da doğrulanır
bash tests/verify-harbor-image-exists.sh
```

İkisi de FAIL (exit≠0) verirse, `01-require-signed-images.yaml.tpl`'in
`deny-non-harbor-images` kuralı ilk gerçek `XPostgreSQLInstance` claim'inde
Postgres Cluster pod'unu SESSİZCE `ImagePullBackOff`/politika reddiyle
başarısız kılar — bu iki script bunu provizyon ÖNCESİNDE, görünür şekilde
yakalamak içindir.
