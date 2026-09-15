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
| PostgreSQL verisi (WAL/PITR) | CNPG Barman, sürekli WAL archiving | **Dakikalar** (CNPG'nin `archive_timeout` varsayılanına bağlı — WAL segmentleri sürekli Ceph RGW'ye akar, günlük bir backup'ı BEKLEMEZ) | ÖLÇÜLMEDİ — gerçek bir CNPG PITR restore tatbikatı bu görevde YAPILMADI (bkz. aşağıdaki "Açık iş") |
| Ceph'in TAMAMEN kaybı (donanım felaketi) | Yalnızca `VELERO_OFFSITE_ENABLED=true` ile küme-dışı ikincil hedef | Offsite AÇIKSA: birincil ile AYNI (≤24s, 20dk kaydırmalı ikinci Schedule); KAPALIYSA: **TÜM yedekler kaybedilir** (bkz. "KRİTİK MİMARİ RİSK") | ÖLÇÜLMEDİ — gerçek donanım/Ceph yeniden kurulumu bu ortamda test EDİLEMEDİ (fiziksel disk yok) |

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
