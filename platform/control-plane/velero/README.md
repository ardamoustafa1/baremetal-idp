# Velero — K8s obje/PV yedekleme

Faz 12h, code review #11/#12'nin çözümü. Kurulum: `platform/bootstrap/06-velero.sh`
(bkz. o script'in başlığı) + `apps/02-velero.yaml.tpl` (ArgoCD'nin sonradan
devralması için — otomatik sync KASITLI OLARAK KAPALI, `Loki`/`Tempo` ile
AYNI gerekçe: S3 sırrı Git'e yazılamaz).

## Ne yedekleniyor, ne yedeklenmiyor

| Kapsam | Velero ile yedekleniyor mu? | Gerçek mekanizma |
|---|---|---|
| Namespace/RBAC/Secret/ConfigMap/CRD/Certificate/Issuer (K8s objeleri) | ✅ Evet | Velero → Ceph RGW (`values.yaml.tpl`) |
| PostgreSQL veritabanı içeriği (PV) | ❌ Velero İLE DEĞİL | CNPG'nin KENDİ Barman/WAL-archiving PITR mekanizması (`compositions/postgresql/function.k` §1/§3, ZATEN Ceph RGW'ye yazıyor) |
| Diğer PV'lerin (Loki/Tempo/Harbor) içeriği | ❌ Hayır | CSI volume snapshot entegrasyonu bilinçli olarak KAPSAM DIŞI — bkz. aşağıdaki not |

**DÜZELTME (Faz 12j, code review #9):** yukarıdaki tablo "PostgreSQL verisi
Velero'nun kapsamı DIŞINDA, ama CNPG kendi mekanizmasıyla ZATEN Ceph RGW'ye
yazıyor" diyordu — bu DOĞRU ama EKSİKTİ: hem Postgres'in Barman verisi HEM
DE Velero'nun K8s obje yedeği AYNI Ceph RGW'ye yazıldığı için, `VELERO_
OFFSITE_ENABLED=true` yalnızca K8s objelerini küme-dışına taşıyordu —
Postgres'in GERÇEK veritabanı içeriğinin BAĞIMSIZ bir kopyası YOKTU. Artık
`06-velero.sh`'in `setup_postgres_offsite_sync()` adımı, HER tenant Postgres
instance'ının backup bucket'ını (`<tenantRef>-<name>-backup`) GÜNLÜK olarak
(04:00 UTC, Velero'nun K8s obje senkronundan 1 saat sonra) offsite hedefe
senkronize eden AYRI bir CronJob kurar — yalnızca `VELERO_OFFSITE_ENABLED=
true` iken. Diğer PV'ler (Loki/Tempo/Harbor) hâlâ KAPSAM DIŞI (CSI snapshot
gerektirir, aşağıdaki not).

**CSI volume snapshot NEDEN kapsam dışı:** `docs/runbooks/disaster-recovery.md`
§3.1/§8a'daki GERÇEK bir DR tatbikatında (kind + Velero + MinIO), Velero'nun
K8s obje restore'u BAŞARILI oldu ama CNPG Postgres'in PV içeriği (CSI volume
snapshot entegrasyonu/`VolumeSnapshotClass` hiç kurulu OLMADIĞI için) restore
EDİLEMEDİ — canlı olarak kanıtlanmış, dokümante edilmiş, AYRI bir iş olarak
işaretlenmiş bir sınır. Bu kurulum o sınırı GENİŞLETMEDİ; yalnızca K8s obje
yedeklemesini üretim GitOps akışına GERÇEKTEN bağladı (önceden bu HİÇ
kurulu değildi).

## RPO / RTO (kabul edilen veri kaybı ve geri dönüş süresi)

| Veri sınıfı | Mekanizma | RPO (kabul edilen veri kaybı) | RTO ölçümü |
|---|---|---|---|
| K8s objeleri (namespace, RBAC, Secret, CRD, ...) | Velero, günlük 03:00 UTC | **≤ 24 saat** (bir sonraki 03:00'a kadar yapılan HERHANGİ bir değişiklik, bir önceki backup'tan SONRAYSA kaybedilebilir) | K8s obje restore'u: **saniyeler-dakikalar** (GERÇEK ölçüm, bkz. disaster-recovery.md §8a: "Completed, saniyeler içinde" — kind+MinIO'da) |
| PostgreSQL verisi (WAL/PITR), BİRİNCİL Ceph RGW'de | CNPG Barman, sürekli WAL archiving | **Dakikalar** (CNPG'nin `archive_timeout` varsayılanına bağlı — WAL segmentleri sürekli Ceph RGW'ye akar, günlük bir backup'ı BEKLEMEZ) | ÖLÇÜLMEDİ — gerçek bir CNPG PITR restore tatbikatı bu görevde YAPILMADI (bkz. aşağıdaki "Açık iş") |
| PostgreSQL verisinin offsite KOPYASI | `setup_postgres_offsite_sync()`, günlük 04:00 UTC | **≤ 24 saat** (yalnızca `VELERO_OFFSITE_ENABLED=true` iken var — KAPALIYSA offsite kopya YOK) | ÖLÇÜLMEDİ — bu senkron mekanizması bu görevde GERÇEK bir Ceph RGW/offsite S3'e karşı ÇALIŞTIRILMADI (statik olarak tasarlandı, bkz. aşağıdaki "Açık iş") |
| Ceph'in TAMAMEN kaybı (donanım felaketi) | Yalnızca `VELERO_OFFSITE_ENABLED=true` ile küme-dışı ikincil hedef (HEM K8s objeleri HEM Postgres verisi) | Offsite AÇIKSA: birincil ile AYNI (≤24s); KAPALIYSA: **TÜM yedekler (K8s objeleri VE Postgres verisi) kaybedilir** (bkz. "KRİTİK MİMARİ RİSK") | ÖLÇÜLMEDİ — gerçek donanım/Ceph yeniden kurulumu bu ortamda test EDİLEMEDİ (fiziksel disk yok) |

**Dürüstlük notu:** yukarıdaki RTO satırlarının ikisi "ÖLÇÜLMEDİ" diyor —
bunu "çalışıyor" diye iddia etmek yanlış olurdu. Yapılan TEK gerçek, uçtan
uca ölçüm `disaster-recovery.md`'nin kind+MinIO tatbikatındaki Velero K8s
obje restore süresidir. `06-velero.sh --only schedule-test`, kurulumun
GERÇEKTEN bir backup ALABİLDİĞİNİ (tamamlanma dahil) her çalıştırmada
kanıtlar — ama bu bir RESTORE testi değildir.

## KRİTİK MİMARİ RİSK (bkz. disaster-recovery.md §3.1)

Velero'nun BİRİNCİL (ve `VELERO_OFFSITE_ENABLED=false` iken TEK) hedefi
Rook-Ceph RGW'dir — yani yedekler, yedekledikleri KÜMENİN ÜZERİNDE durur.
Ceph'in tamamen kaybı, Velero'nun yedeklerini de BİRLİKTE götürür. Bunun
tek gerçek azaltımı, `.env`'de `VELERO_OFFSITE_ENABLED=true` + gerçek bir
küme-dışı S3 uç noktası tanımlamaktır (bkz. `.env.example`). Üretimde bu
**şiddetle önerilir** — varsayılan `false` yalnızca sahte/icat edilmiş bir
uç nokta yazmamak içindir, "gerekli değil" anlamına GELMEZ.

## Açık iş (bu görev kapsamında YAPILMADI)

- CSI volume snapshot entegrasyonu (Rook-Ceph RBD/CephFS `VolumeSnapshotClass`
  + `snapshot.storage.k8s.io` CRD'leri) — disaster-recovery.md'de ÖNCEDEN
  işaretli, ayrı bir iş.
- Gerçek bir CNPG PITR restore tatbikatı (bootstrap.recovery ile bir
  yedekten yeni bir Cluster oluşturup veri bütünlüğünü doğrulamak) —
  bkz. `compositions/postgresql/README.md` "Restore" bölümü (varsa) /
  CNPG'nin resmi `bootstrap.recovery` dokümantasyonu.
- Gerçek bir donanım/Ceph-kaybı DR tatbikatı (bu ortamda fiziksel disk yok).
- `setup_postgres_offsite_sync()`'in ve `setup_offsite_sync_discovery_cronjob()`'un
  (Faz 12m) GERÇEK bir Ceph RGW + offsite S3'e karşı UÇTAN UCA çalıştırılması
  (statik olarak tasarlandı; `rclone`'un `lsd`/`mkdir`/`sync`/`check`
  komutlarının syntax'ı ve şablon render'ı incelendi — `envsubst` + YAML
  parse ile DOĞRULANDI — ama canlı bir Ceph RGW/offsite S3 çiftine karşı
  ÇALIŞTIRILMADI).
- Kaynak Ceph kullanılamazken (yalnızca offsite hedeften) bir Postgres
  restore denemesi — `compositions/postgresql/README.md`'nin YENİ "Offsite'tan
  restore — CANLIYA GEÇMEDEN ÖNCE ZORUNLU" bölümü (code review #9) TAM bir
  prosedür + kabul kriterleri (veri bütünlüğü, PITR, ÖLÇÜLEN RPO/RTO)
  yazdı — ama bu HİÇ ÇALIŞTIRILMADI (gerçek Ceph/offsite S3 yok).
- **DÜZELTME (code review #5, KRİTİK):** offsite-sync CronJob'u ÖNCEDEN
  `rclone sync` kullanıyordu — bu, hedefi kaynakla BİREBİR eşitler (kaynakta
  OLMAYAN nesneleri hedeften SİLER). Kaynak bucket YANLIŞLIKLA silinirse,
  BİR SONRAKİ günlük çalıştırma offsite'taki yedekleri de silerdi — "bağımsız
  bir ikinci kopya" tasarımının TEMEL AMACINI ihlal ediyordu. `rclone copy`'ye
  geçirildi (yalnızca EKLER, hedeften HİÇBİR ŞEY SİLMEZ) + boş-kaynak/dolu-hedef
  durumunda Job'u AÇIKÇA başarısız sayan bir koruma eklendi. Offsite artık
  YALNIZCA BİRİKİR (disk kullanımı zamanla artar — bilinçli maliyet/güvenlik
  ödünleşimi) — GERÇEK bir Ceph/S3'e karşı canlı test EDİLEMEDİ.
- **DÜZELTME (code review #6, YÜKSEK):** `offsite-sync-discovery`
  ServiceAccount'ının küme-geneli `secrets: get` yetkisi (ele geçirilirse
  ADI BİLİNEN HER namespace'in HER Secret'ını okuyabilirdi) KALDIRILDI —
  `compositions/postgresql/function.k` artık HER Postgres instance'ı KENDİ
  namespace'inde, discovery SA'sına `resourceNames` ile TEK BİR Secret'a
  (o instance'ın KENDİ backup Secret'ı) SINIRLI bir Role/RoleBinding
  oluşturuyor.
- **DÜZELTME (code review #7, YÜKSEK):** discovery script'i ÖNCEDEN OBC
  listeleme HATASINI (`kubectl get ... || true`) "sıfır kaynak var" ile
  AYNI şekilde yorumluyordu — bir API/RBAC arızası SESSİZCE "başarılı,
  yedeklenecek veritabanı yok" görünebilirdi. Artık kubectl'in KENDİ exit
  kodu ayrı yakalanıyor (hata → Job FAIL) ve atlanan HER secret-okuma
  hatası SAYILIYOR (en az bir atlama varsa Job SONUNDA FAIL).
- **DÜZELTME (code review #8, YÜKSEK):** `offsite-sync` namespace'i
  `DEFAULT_DENY_EXEMPT_NAMESPACES`'te (`.env.example`) HİÇ YOKTU —
  `ENABLE_DEFAULT_DENY=true` olduğunda discovery'nin K8s API'ye, sync'in
  Ceph RGW'ye/offsite S3'e giden trafiği SESSİZCE KESİLİRDİ. Eklendi —
  velero/cnpg-system gibi diğer platform namespace'leriyle AYNI (GENİŞ,
  teknik borç #3'e bilinçli olarak bırakılmış) istisna deseninde; DAR,
  yalnızca gereken hedeflere özel bir CiliumNetworkPolicy YAZILMADI.
- Backup smoke test'in (`run_backup_smoke_test()`) Faz 12m'de kesin faz
  eşitliği + hata sayısı kontrolüne güçlendirilmesi CANLI test edildi
  (bkz. Faz 12m günlüğü) AMA test hâlâ yalnızca Velero'nun KENDİ namespace'inin
  K8s objelerini yedekliyor — gerçek bir restore, Postgres verisi veya
  offsite yolu HİÇBİR ZAMAN test edilmiyor. Bu, `run_backup_smoke_test()`'in
  KENDİ doc-comment'inde AÇIKÇA işaretli, bilinçli bir kapsam sınırı.
- ~~**Bilinçli sınır:** `setup_postgres_offsite_sync()` yalnızca ÇALIŞTIĞI
  ANDA var olan postgres backup bucket'larını keşfeder...~~ **Faz 12m'de
  ÇÖZÜLDÜ:** `setup_offsite_sync_discovery_cronjob()`, `offsite-sync`
  namespace'ine SAATLİK çalışan bir CronJob kurar — bu CronJob AYNI keşif
  mantığını (postgres backup OBC'lerini `platform.internal/component=postgresql`
  etiketiyle listeler, her biri için offsite-sync CronJob/Secret'ını
  OTOMATİK oluşturur/günceller) küme İÇİNDEN, insan müdahalesi OLMADAN
  periyodik tekrarlar. Kalan bilinçli sınır: SONRADAN oluşturulan bir
  Postgres instance'ı artık EN GEÇ 1 SAAT içinde otomatik keşfedilir
  (öncesinde: asla, elle re-run olmadan) — ama HÂLÂ "yedeksiz kalan bir
  prod veritabanı için ALARM" ÜRETİLMİYOR (yalnızca reconciliation var,
  gözlemlenebilirlik/alerting entegrasyonu YOK — bu ayrı bir iş).

## Dosya sistemi yedeklemesi ve kapsama kontrolü

Node-agent artık etkindir (chart 7.2.1 / Velero 1.14.1 / AWS plugin 1.10.1).
Dosya yedeği açık katılımla çalışır: Deployment/StatefulSet pod şablonunda
`backup.velero.io/backup-volumes: data` annotation’ı kullanılır; `data`, PVC
adı değil `spec.volumes[].name` değeridir. Birden çok volume virgülle ayrılır.
Günlük yerel ve offsite planları bu annotation’ları kullanır; snapshot kapalıdır.
Canlı veritabanı dosyalarını tutarlı yedek saymayın. CNPG için Barman/PITR,
Vault için Raft snapshot ve gerekli recovery anahtarları ayrıca korunmalıdır.

İlk FSB kurulumu öncesi `VELERO_REPOSITORY_PASSWORD_FILE` ile güçlü parolayı
bir dosyadan sağlayın ve bağımsız güvenli konumda saklayın. Script mevcut
`velero-repo-credentials` Secret’ını değiştirmez. Mevcut repo parolasını
kaybetmek veya değiştirmek eski Kopia yedeklerini erişilemez yapabilir.

`platform/tests/readiness/check-live.py --context <test-context>` her Bound
PVC için yakın tarihli tamamlanmış FSB veya CNPG yedeği arar. Annotation’ın
varlığı başarı sayılmaz. Native yedeği olan Vault gibi kaynaklar otomatik
FSB/CNPG kontrolünde açık kalır; uygulamaya özgü kurtarma kanıtı ayrıca
incelenmeden genel hazır kararı verilmez.
