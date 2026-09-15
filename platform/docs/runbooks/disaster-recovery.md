# Runbook: Felaket Kurtarma (Disaster Recovery)

| Alan | Değer |
|---|---|
| Kapsam | Tüm cluster kaybı senaryosu — Kubernetes objeleri (Velero), Vault (Raft snapshot), Rook-Ceph (veri), ve "Git tek gerçek kaynak" prensibinin uçtan uca doğrulanması |
| Sıklık | Tatbikat: 6 ayda 1 (planlı). Gerçek olay: bkz. §7 "Gerçek bir felakette" |
| Önkoşul | `platform/control-plane/velero/` (bkz. §0 — henüz KURULU DEĞİL, bu runbook'un ön koşuludur), Vault audit/unseal runbook'ları tamamlanmış |
| Temel prensip | **Git her zaman gerçek kaynak (source of truth)'tır — cluster tamamen kaybolsa bile, Git + (Velero'nun sakladığı) veri/secret durumu ile HER ŞEY yeniden inşa edilebilir olmalıdır.** |

> **DÜRÜSTLÜK NOTU (güncellendi — Faz 12):** Faz 10'da bu runbook yalnızca
> YAZILMIŞ, hiç test edilmemişti. **Faz 12'de kind + gerçek Velero + MinIO
> (Rook-Ceph RGW yerine geçen bir stand-in S3 backend) ile GERÇEK bir DR
> tatbikatı UYGULANDI** — bkz. §8a. Namespace/RBAC/Secret/Issuer/Certificate
> BAŞARIYLA restore edildi; CNPG'nin GERÇEK Postgres verisi ise (CSI volume
> snapshot entegrasyonu OLMADIĞI için) RESTORE EDİLEMEDİ — tam da §3.1'in
> önceden işaretlediği riskin CANLI kanıtı. Kabul kriteri #3 ("en az bir kez
> denenmiş ve sonuçları belgelenmiş") artık **KISMEN karşılanıyor**: K8s
> objeleri için TAM, PV verisi için HENÜZ DEĞİL (CSI snapshot entegrasyonu
> ayrı bir iş). Rook-Ceph OSD'li/Vault Raft'lı TAM bir bare-metal tatbikat
> hâlâ yapılmadı (bu ortamda fiziksel disk yok) — MinIO/kind, yalnızca
> Velero'nun MEKANİZMASINI (K8s obje yedekleme/geri yükleme) gerçek olarak
> kanıtladı, Rook-Ceph'in KENDİSİNİ değil.

---

## 0. Ön koşul: Velero kurulumu (bu runbook'un dışında, ayrı bir görev)

Bu runbook, Velero'nun ŞÖYLE kurulu olduğunu VARSAYAR (henüz yazılmadı —
`platform/control-plane/velero/` şu an boş):

- Velero, Rook-Ceph RGW'yi (S3 uyumlu) backup hedefi olarak kullanır (Harbor/
  Loki/Tempo'nun OBC deseniyle AYNI: `rook-ceph` namespace'inde bir OBC).
- Günlük zamanlanmış backup (`velero schedule create daily --schedule="0 3 * * *"`),
  tüm namespace'ler + cluster-scoped kaynaklar (CRD'ler, ClusterPolicy'ler,
  PriorityClass'lar) dahil.
- CSI snapshot desteği (Rook-Ceph RBD/CephFS VolumeSnapshotClass'ları ile)
  PV içeriğinin de yedeklenmesi için AÇIK.

---

## 1. Felaket senaryoları ve kapsam

| # | Senaryo | Bu runbook'un kapsadığı mı? |
|---|---|---|
| A | Tek bir tenant namespace'i yanlışlıkla silindi | ✅ §5 (Velero namespace-restore) |
| B | Vault verisi bozuldu/kayboldu (3 pod da, Raft quorum kaybı) | ✅ §4 (Vault Raft snapshot restore) |
| C | Rook-Ceph OSD'lerin tamamı/çoğu kayboldu (disk arızası, node kaybı) | ✅ §3 (Rook-Ceph DR) |
| D | **TÜM cluster kayboldu** (kontrol düzlemi + tüm node'lar, sıfırdan yeni donanım) | ✅ §6 (tam yeniden inşa) — DİĞER TÜM SENARYOLARIN BİRLEŞİMİ |
| E | Git reposunun kendisi kayboldu | ❌ KAPSAM DIŞI — bu, ayrı bir Git-hosting DR konusudur (GitHub'ın kendi yedekleme SLA'sına güvenilir; platformun repo'yu ayrıca yedeklemesi bu görevde İSTENMEDİ) |

---

## 2. Neyin nerede yedeklendiği — TEK bakış tablosu

| Veri sınıfı | Yedekleme mekanizması | Saklama yeri | Geri yükleme aracı |
|---|---|---|---|
| K8s objeleri (Deployment, Service, CRD, RBAC, ...) | Velero | Rook-Ceph RGW (S3) | `velero restore` |
| PV içeriği (Postgres, Loki/Tempo veri, Harbor registry) | Velero CSI snapshot (Rook-Ceph VolumeSnapshot) | Rook-Ceph RGW (S3, snapshot metadata) + Ceph'in kendi RBD/CephFS snapshot mekanizması | `velero restore` (PVC'yi otomatik snapshot'tan yeniden oluşturur) |
| Vault'un KENDİ verisi (secret'lar, PKI, auth config) | Vault'un Raft `snapshot save` komutu | Harici depolama (bkz. §4 — Velero'nun YEDEKLEMEDİĞİ, AYRI bir mekanizma) | `vault operator raft snapshot restore` |
| Rook-Ceph'in KENDİSİ (mon quorum, OSD map, CRUSH map) | Ceph'in kendi mon/OSD durumu + `rook-ceph-mon` Secret'ları (Velero ile yedeklenir) | Velero (K8s Secret'ları) + fiziksel disklerin kendisi | §3, disk durumuna göre değişir |
| **Git reposu (bu repo)** | GitHub'ın kendi altyapısı | GitHub | `git clone` (§6 adım 1) |
| `.env` dosyaları (GERÇEK sırlar — Git'te YOK) | **BU RUNBOOK'UN KAPSAMI DIŞINDA — ayrı bir sır-yedekleme prosedürü GEREKİR** | — | — |

**KRİTİK BOŞLUK (bilinçli, işaretlendi):** `.env` dosyaları (Harbor/Keycloak
parolaları, `ALERTMANAGER_WEBHOOK_URL`, `OPENCOST_*_HOURLY_COST` vb.) Git'e
YAZILMAZ (bkz. `underlay/README.md` "Sırlar ve parametreler") — bu KASITLI
bir güvenlik kararıdır ama DR açısından bir TEHLİKEDİR: `.env` dosyalarının
KENDİSİ de bir yerde (parola yöneticisi, şifreli bir yedek) saklanmadıkça,
"Git tek gerçek kaynak" prensibi TAM ANLAMIYLA doğru DEĞİLDİR — Git,
YAPIYI (nasıl kurulacağını) saklar ama GERÇEK DEĞERLERİ (parolalar)
SAKLAMAZ. Bu runbook'un §6'sı bu boşluğu AÇIKÇA varsayım olarak işaretler.

---

## 3. Rook-Ceph felaketi (OSD/disk kaybı)

```bash
# 1. Ceph cluster durumunu değerlendirin:
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
# HEALTH_ERR + "x osds down" / "y pgs stale" görüyorsanız devam edin.

# 2. Kaybedilen OSD sayısı REPLİKA FAKTÖRÜNÜ (varsayılan 3x) AŞMADIYSA,
#    Ceph KENDİ KENDİNİ onarır (self-healing) — yeni bir OSD disk'i
#    eklendiğinde veri otomatik yeniden dengelenir (rebalance):
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
# "down"/"out" OSD'leri temizleyip yeni disk eklemek için:
#   platform/underlay/rook-ceph/README.md "OSD ekleme/çıkarma"

# 3. Kaybedilen OSD sayısı replika faktörünü AŞTIYSA (veri kaybı KESİN):
#    Rook-Ceph cluster'ı SIFIRDAN kurulur (01-underlay.sh --only rook),
#    TÜM veri (Harbor registry, Loki/Tempo chunk'ları, Postgres PV'leri,
#    Vault'un auditStorage'ı) KAYBOLUR — bu noktadan sonra §6 (tam yeniden
#    inşa) izlenir, Velero'nun ONLİNE olduğu bir ZAMANDAN alınan EN SON
#    yedek geri yüklenir (bu yedeğin KENDİSİ Rook-Ceph RGW'de saklandığı
#    için, Rook TAMAMEN kaybolduysa bu yedek de KAYBOLUR — bkz. §3.1).
```

### 3.1 KRİTİK MİMARİ RİSK — Velero'nun yedeği Rook-Ceph'in ÜZERİNDE duruyor

Bu platformda Velero'nun S3 hedefi Rook-Ceph RGW'dir (Loki/Tempo/Harbor ile
AYNI desen — bkz. PLATFORM_CONTEXT.md). **Rook-Ceph'in KENDİSİ tamamen
kaybolursa, Velero'nun yedekleri de onunla BİRLİKTE kaybolur** — Velero
kendi depolama katmanını YEDEKLEYEMEZ. Bu, "tek nokta bağımlılığı"
(single point of failure) niteliğinde bir tasarım riskidir.

**Zorunlu azaltma (bu görev kapsamında UYGULANMADI, açık iş):** Velero'nun
S3 hedefinin **cluster DIŞI** bir yere (örn. gerçek bir bulut S3 kovası,
veya coğrafi olarak ayrı bir ikinci Ceph cluster'ı) de replike edilmesi
gerekir — `velero backup-location create` ile ikinci bir
`BackupStorageLocation` eklenip zamanlanmış yedeklerin İKİ hedefe de
yazılması ÖNERİLİR. Bu, PLATFORM_CONTEXT.md'ye teknik borç olarak
kaydedildi.

---

## 4. Vault Raft snapshot yedekleme/geri yükleme

Vault'un KENDİ verisi (PKI, auth config, KV secret'ları) Velero'nun
kapsamı DIŞINDADIR (Velero yalnızca K8s objelerini/PV'leri yedekler, Raft
storage'ın İÇERİĞİNİ tutarlı bir şekilde YEDEKLEMEZ — Vault'un kendi
mekanizması kullanılmalıdır).

```bash
# --- Yedekleme (günlük, zamanlanmış bir CronJob'a taşınmalı — bu görev
#     kapsamında yalnızca ELLE komut olarak yazıldı, otomasyonu AYRI iş) ---
export VAULT_TOKEN=<yetkili bir token, root DEĞİL — bkz. vault-break-glass.md>
kubectl -n vault exec vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} \
   vault operator raft snapshot save /tmp/raft-$(date +%Y%m%d).snap"
kubectl -n vault cp vault-0:/tmp/raft-$(date +%Y%m%d).snap ./raft-backup.snap
# Bu dosya CLUSTER DIŞINA taşınmalıdır (S3/offsite) — yerel diskte
# bırakılması §3.1'deki AYNI riski taşır.

# --- Geri yükleme (Vault YENİDEN init edilip unseal edildikten SONRA) ---
kubectl -n vault cp ./raft-backup.snap vault-0:/tmp/restore.snap
kubectl -n vault exec vault-0 -- sh -c \
  "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN} \
   vault operator raft snapshot restore /tmp/restore.snap"
# NOT: restore, mevcut TÜM Vault verisinin ÜZERİNE YAZAR — yalnızca gerçek
# bir felakette veya tatbikatta, İZOLE bir test cluster'ında çalıştırılır.
```

---

## 5. Tek bir namespace/tenant kaybı (Velero restore)

```bash
# 1. Namespace'in en son yedeğini bulun:
velero backup get
# 2. Yalnızca o namespace'i geri yükleyin:
velero restore create --from-backup <backup-adı> \
  --include-namespaces tenant-acme-dev
# 3. Doğrulama:
kubectl -n tenant-acme-dev get all
velero restore describe <restore-adı> --details
```

---

## 6. TAM CLUSTER KAYBI — sıfırdan yeniden inşa ("Git tek gerçek kaynak" testi)

Bu, DR tatbikatının ASIL testidir: yeni (veya sıfırlanmış) donanımda,
YALNIZCA bu Git reposu + operatörün elle sakladığı `.env`/parola bilgisiyle
platformun BAŞTAN kurulabildiğini kanıtlar.

```bash
# 1. Git'ten repo'yu çekin (KRİTİK bulgu #E: bu adımın kendisi Git-hosting'in
#    ayakta olmasını varsayar — kapsam dışı, bkz. §1 satır E):
git clone <platform-repo-url> && cd infastruce

# 2. .env dosyalarını YENİDEN oluşturun (parola yöneticisinden/offsite
#    yedekten — bkz. §2 "KRİTİK BOŞLUK"):
cp platform/underlay/.env.example platform/underlay/.env
$EDITOR platform/underlay/.env   # gerçek değerleri parola yöneticisinden girin

# 3. Underlay'i sıfırdan kurun (yeni/boş node'larda):
./platform/bootstrap/01-underlay.sh
#    → Cilium, MetalLB, Rook-Ceph (BOŞ — henüz veri yok), Harbor, Keycloak

# 4. Control plane:
./platform/bootstrap/02-control-plane.sh
#    → ArgoCD, Crossplane, Kyverno, ESO

# 5. PKI: Vault YENİDEN init edilir (bu artık YENİ bir Vault'tur, henüz
#    veri yok) — BURADA İKİ YOL VAR:
#      (a) Sıfırdan yeni bir PKI hiyerarşisi kurun (§5a — TÜM sertifikalar
#          yeniden imzalanır, tüm tenant'ların TLS zinciri DEĞİŞİR)
#      (b) §4'teki Raft snapshot'ı geri yükleyin (§5b — ESKİ PKI/secret
#          durumu KORUNUR, tenant'lar hiçbir şey fark etmez)
#    Tatbikatta (b) TERCİH EDİLİR (gerçek bir felakette veri kaybı
#    olmadığını kanıtlamak asıl amaçtır):
./platform/bootstrap/03-pki.sh --only vault
# ... init/unseal (docs/runbooks/vault-unseal.md) ...
# ardından §4'teki restore komutu çalıştırılır, SONRA:
./platform/bootstrap/03-pki.sh   # kalan adımlar (auth, pki mount kontrolü, cert-manager)

# 6. Gözlemlenebilirlik + OpenCost:
./platform/bootstrap/05-observability.sh

# 7. Backstage:
./platform/bootstrap/04-backstage.sh

# 8. Tenant/Postgres composition'ları ArgoCD'nin app-of-apps'i ile OTOMATİK
#    gelir (04-compositions.yaml.tpl) — elle bir adım GEREKMEZ.

# 9. Velero restore (K8s objeleri + PV'ler) — eğer Rook-Ceph'in KENDİSİ
#    de kayboldu ve YENİDEN kurulduysa (adım 3), Velero'nun YEDEĞİ de
#    muhtemelen KAYBOLMUŞTUR (bkz. §3.1) — bu durumda yalnızca Git'ten
#    yeniden üretilebilen kaynaklar (composition'ların ÜRETTİĞİ her şey)
#    geri gelir, Velero'nun yedeklediği "elle girilmiş" veri (örn. bir
#    kullanıcının Harbor'a push ettiği imajlar) KAYBOLUR. Rook-Ceph
#    KORUNDUYSA (yalnızca kontrol düzlemi kayboldu):
velero restore create --from-backup <en-son-yedek>

# 10. Doğrulama (kabul kriteri): her tenant'ın namespace'i, quota'sı,
#     Postgres'i, sertifikası ESKİSİYLE AYNI DURUMDA mı?
kubectl get tenants.platform.internal -A
kubectl get postgresqlinstances.platform.internal -A
kubectl get certificates -A -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status'
```

---

## 7. Gerçek bir felakette (bu tatbikat DIŞINDA)

1. Olay kaydı açın (kim, ne zaman, hangi senaryo — §1 tablosundaki A-D).
2. Break-glass gerekiyorsa (Vault erişimi kayıpsa) `vault-break-glass.md`
   izlenir.
3. §6'daki adımlar SIRAYLA uygulanır — ADIM ATLANMAZ (özellikle §2'nin
   "Rook-Ceph Velero'nun ÜZERİNDE" riski nedeniyle, hangi bileşenin
   GERÇEKTEN kaybolduğu netleştirilmeden restore'a başlanması veri
   kaybını KALICI hale getirebilir).
4. Kurtarma sonrası bir "post-mortem" ile bu runbook GÜNCELLENİR (eksik
   kalan bir adım varsa).

---

## 8a. GERÇEK bir DR tatbikatı sonucu (Faz 12, kind + Velero + MinIO)

Bu görevde, `kind` cluster'ında GERÇEK bir Velero (MinIO S3 backend'i ile,
Rook-Ceph RGW'nin yerine geçen bir stand-in) kurulup TAM bir tatbikat
uygulandı:

1. Gerçek bir tenant namespace'i (`tenant-acme-dev`, Tenant+Postgres claim'i
   ile TAM composition zincirinden geçmiş: RBAC, Quota, Issuer, CNPG
   Cluster, Certificate) `velero backup` ile yedeklendi — **`Completed`**.
2. Tenant claim'i VE namespace'i SİLİNDİ (Crossplane'in kendi kendini
   iyileştirmesini de devre dışı bırakmak için ÖNCE claim silindi — aksi
   halde Crossplane, namespace silinir silinmez onu KENDİ BAŞINA yeniden
   üretiyordu, bkz. §8b).
3. `velero restore` ile GERİ YÜKLENDİ — **`Completed`**, saniyeler içinde.
4. **Sonuç:** Namespace, TÜM RBAC (cert-manager/ESO ServiceAccount'ları
   dahil), ResourceQuota, Secret'lar (Postgres kimlik bilgileri dahil),
   `tenant-issuer` (ANINDA `Ready=True`, Vault hâlâ ayaktaydı) ve
   `Certificate` (ANINDA `Ready=True`) SORUNSUZ geri geldi.
5. **AMA:** CNPG Cluster pod'u `CrashLoopBackOff`'a düştü —
   `pg_controldata` PGDATA dizininde GEÇERLİ bir Postgres cluster'ı
   BULAMADI. Kök neden: Velero'nun PVC'yi geri yüklemesi YENİ, BOŞ bir
   PersistentVolume'a bağlandı — **gerçek veri (WAL, tablolar) hiç geri
   gelmedi**. Bu, §2 tablosunun ve §3.1'in ÖNCEDEN teorik olarak
   işaretlediği riskin (CSI volume snapshot entegrasyonu OLMADAN Velero
   yalnızca K8s API nesnelerini yedekler, PV İÇERİĞİNİ DEĞİL) CANLI,
   GERÇEK bir kanıtıdır.

**Sonuç/ders:** Üretimde Velero, Rook-Ceph'in CSI VolumeSnapshotClass'ları
(RBD/CephFS) ile entegre ÇALIŞMALIDIR (`--use-volume-snapshots=true` +
gerçek bir `VolumeSnapshotClass`) — bu olmadan "K8s objeleri geri geldi"
YANILTICI bir güven duygusu verir; GERÇEK veri (Postgres tabloları) restore
edilmiş OLMAZ. Bu tatbikat, MinIO/basit bir S3 backend'in yalnızca §2
tablosundaki "K8s objeleri" satırını test ettiğini, "PV içeriği" satırının
AYRI bir mekanizma (CSI snapshot) gerektirdiğini SOMUT OLARAK kanıtladı.

## 8b. İkincil bulgu: Crossplane'in kendi kendini iyileştirmesi

İlk denemede yalnızca NAMESPACE silindiğinde (Tenant claim/XR HÂLÂ
duruyorken), Crossplane'in kendi reconciliation döngüsü namespace'i
Velero'dan BAĞIMSIZ olarak KENDİLİĞİNDEN yeniden üretti (birkaç saniye
içinde) — Velero restore'una hiç GEREK KALMADAN. Bu, Crossplane-yönetimli
kaynaklar için ÖNEMLİ bir pratik sonuç: **saf bir "namespace/kaynak silindi"
felaketi için Velero'YA GEREK YOKTUR** — Crossplane zaten kendi composite
kaynağından yeniden üretir. Velero'nun asıl değeri (1) Crossplane'in
KENDİSİNİN de kaybolduğu (XR/Claim'in etcd'den silindiği) senaryolarda VEYA
(2) Crossplane'in YÖNETMEDİĞİ veri (Postgres tabloları gibi) içindir.

## 8. Bu görevde gerçekten yapılan / yapılmayan

**Yapılan:**
- Bu runbook'un TAMAMI yazıldı ve mevcut platform mimarisiyle (OBC
  deseni, `.env`/Git ayrımı, bootstrap script sıralaması) TUTARLI olacak
  şekilde çapraz kontrol edildi.
- §3.1'deki mimari risk (Velero yedeğinin Rook-Ceph'in üzerinde durması)
  gerçek bir mimari inceleme sonucu KEŞFEDİLDİ ve açıkça belgelendi —
  bu, görev metninde İSTENMEYEN ama runbook'u YAZARKEN ortaya çıkan
  GERÇEK bir bulgudur.

**YAPILMAYAN (açıkça işaretli):**
- ❌ Velero'nun kendisi bu ortamda/gerçek bir cluster'da KURULMADI
  (`platform/control-plane/velero/` hâlâ boş — ayrı bir görev/faz).
- ❌ Bu runbook, gerçek bir test cluster'ında UÇTAN UCA ÇALIŞTIRILMADI —
  bu ortamda çok-node'lu, Rook-Ceph OSD'li, Vault Raft'lı bir cluster YOK
  ve bu görev kapsamında kurulması İSTENMEDİ (yalnızca runbook'un
  YAZILMASI istendi, ki bu tamamlandı).
- ❌ Dolayısıyla kabul kriteri #3 ("en az bir kez test cluster'ında
  denenmiş ve sonuçları belgelenmiş") **KARŞILANMADI** — bu görevin geri
  kalan tüm maddelerinin aksine (1, 3, 4, 5 GERÇEK araçlarla doğrulandı),
  bu madde yalnızca STATİK/mimari incelemeyle üretildi. Bir sonraki adım
  olarak, Velero + Rook-Ceph + Vault'un GERÇEKTEN kurulu olduğu bir test
  cluster'ında bu runbook'un baştan sona çalıştırılması ve sonuçların
  (başarılı/başarısız her adım) bu dosyanın §9'una (yeni bir bölüm)
  eklenmesi GEREKİR.
