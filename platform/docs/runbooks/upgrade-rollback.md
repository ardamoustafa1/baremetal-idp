# Runbook: Crossplane / cert-manager / ArgoCD / Kyverno Sürüm Yükseltme + Geri Alma

> **SAPMA NOTU:** Görev metni teslimi `docs/runbooks/upgrade-rollback.md`
> olarak istedi; ADR-0001'in belge yerleşimiyle (`platform/docs/runbooks/`)
> tutarlı olması için bu yol kullanıldı (önceki her fazda uygulanan aynı
> kural).

| Alan | Değer |
|---|---|
| Kapsam | Crossplane, cert-manager, ArgoCD, Kyverno — tüm ArgoCD app-of-apps ile yönetilen kritik kontrol düzlemi bileşenleri |
| Sıklık | İhtiyaç bazlı (güvenlik yaması, yeni özellik) — asgari 6 ayda 1 sürüm taraması |
| Temel prensip | **Her yükseltme önce bir kind/test cluster'ında, SONRA üretimde; her yükseltmenin geri alma adımı ÖNCEDEN yazılı olmalı — "umarım geri alabiliriz" bir plan DEĞİLDİR.** |

---

## 0. Bu runbook'un varlık nedeni (Faz 11'de GERÇEKTEN yaşandı)

Bu görevde, `platform/underlay/versions.env`'in **Crossplane 1.18.0** pini,
GERÇEK bir test cluster'ında (`tests/e2e/kind-chain/`) çalıştırılana kadar
KİMSE tarafından fark edilmemiş, ÜRETİME ÇIKSA HER TENANT PROVİZYONUNU
kalıcı olarak bozacak bir sürüm uyumsuzluğu içeriyordu (bkz.
PLATFORM_CONTEXT.md Faz 11 günlüğü). Bu, "yalnızca `crossplane render`
(statik) ile doğrulanmış bir sürüm pini güvenlidir" varsayımının YANLIŞ
olduğunu KANITLADI — bu runbook'un §2'sindeki "önce test cluster'ında
GERÇEKTEN reconcile ettir" adımı bu yüzden ZORUNLU, opsiyonel değildir.

---

## 1. Genel yükseltme sırası ve gerekçe

```
1. Kyverno       (guardrail'ler — diğer her şeyden ÖNCE, bir yükseltme
                  sırasında geçici olarak "korumasız" kalınmasın)
2. cert-manager  (PKI zinciri — Vault/Issuer'lar bozulursa TÜM sertifika
                  yenilemeleri durur, bu yüzden erken ve izole test edilir)
3. Crossplane    (tenant API çalışma zamanı — en KARMAŞIK/riskli yükseltme,
                  bkz. §0; provider/function paketleri Crossplane çekirdeğinden
                  SONRA gelir)
4. ArgoCD        (GitOps motoru — SON, çünkü diğer hepsinin senkronizasyonunu
                  ArgoCD YÖNETİR; ArgoCD'nin kendisi bozulursa diğer
                  bileşenlerin durumu deploy zamanında DONMUŞ kalır ama
                  ÇALIŞAN workload'lar ETKİLENMEZ — bu yüzden en düşük
                  riskli SON adım)
```

**Neden bu sıra, tersi DEĞİL:** Kyverno önce gelir çünkü guardrail'lerin
KENDİSİ bir yükseltme sırasında geçersiz/eksik kalırsa (örn. yeni bir
Kyverno sürümü eski `ClusterPolicy` şemasını reddederse), platform BİR
SÜRE korumasız kalır — bu riski en aza indirmek için önce test edilir.
ArgoCD en son gelir çünkü GitOps motorunun KENDİSİ bir yükseltme sırasında
kısa süreliğine "senkron değil" görünse de, zaten uygulanmış olan
kaynaklar (Deployment/Service/vb.) ÇALIŞMAYA DEVAM EDER — ArgoCD yalnızca
YENİ değişiklikleri uygulayamaz, mevcut durumu BOZMAZ.

---

## 2. Genel prosedür (her bileşen için ORTAK adımlar)

### 2.1 Test cluster'ında doğrulama (ZORUNLU, bkz. §0)

```bash
kind create cluster --name upgrade-test --wait 120s
# İlgili bileşeni YENİ sürümle kur (helm upgrade --install ...)
# Bu repo'nun GERÇEK composition'larını/politikalarını UYGULA (bkz.
# tests/e2e/kind-chain/run.sh, platform/policies/tests/):
bash tests/e2e/kind-chain/run.sh          # Crossplane yükseltmeleri için
kyverno test platform/policies/tests/     # Kyverno yükseltmeleri için
# Sonuç YEŞİL değilse üretime GEÇİLMEZ.
kind delete cluster --name upgrade-test
```

### 2.2 `versions.env` güncelleme + PR

Sürüm pini TEK BİR COMMIT'te güncellenir, PR açıklamasında:
- Değişiklik günlüğü (CHANGELOG) linki,
- Test cluster sonucu (2.1'in çıktısı),
- Geri alma planı (bu bileşenin §3-6'sındaki ilgili bölüme link)
bulunur. `platform-ci.yaml` (Faz 11) bu PR'da composition+policy
testlerini OTOMATİK çalıştırır.

### 2.3 Üretimde kademeli uygulama

`02-control-plane.sh --only <bileşen>` (veya `01-underlay.sh --only
cilium` gibi ilgili script) ile TEK bir bileşen güncellenir — asla
"hepsini birden yükselt" YAPILMAZ. Her adımdan sonra `--verify-only` ile
doğrulama.

### 2.4 Gözlem penceresi

Her yükseltmeden sonra EN AZ 30 dakika (kritik bileşenler için 24 saat)
gözlemlenir: `kubectl get events -A --sort-by=.lastTimestamp`,
Prometheus'ta hata oranı artışı (`control-plane/observability/`, Faz 9),
ArgoCD Application'larının `Synced`/`Healthy` kalması.

---

## 3. Crossplane

### Yükseltme

1. §2.1'i çalıştır — **ÖZELLİKLE bu bileşen için ZORUNLU** (bkz. §0).
2. `provider-kubernetes`/`provider-helm`/`provider-terraform`/`function-kcl`/
   `function-auto-ready` paketlerinin YENİ Crossplane sürümüyle uyumlu
   olduğunu `kubectl get providers,functions.pkg.crossplane.io` ile
   (Healthy=True) doğrula — Crossplane çekirdeği ile paket API'leri
   arasında ayrı bir uyumluluk matrisi vardır.
3. `versions.env`'in `CROSSPLANE_CHART_VERSION`'ını güncelle.
4. `02-control-plane.sh --only crossplane`.
5. **KRİTİK KONTROL:** mevcut TÜM tenant/postgres XR'larının
   `SYNCED=True` kaldığını doğrula:
   ```bash
   kubectl get xtenants.platform.internal,xpostgresqlinstances.platform.internal -A \
     -o custom-columns=NAME:.metadata.name,SYNCED:'.status.conditions[?(@.type=="Synced")].status'
   ```
   Herhangi biri `False`'a düşerse DERHAL §3 geri alma.

### Geri alma

```bash
helm rollback crossplane <önceki-revizyon> -n crossplane-system
# provider/function paketleri OTOMATİK eski sürüme dönmez — Package
# CR'larının targetRevision'ı ELLE eski image tag'ine döndürülmeli:
kubectl edit function.pkg.crossplane.io/function-kcl   # spec.package: eski tag
```

**Rollback riski:** Crossplane, XR'ların `spec.resourceRefs` alanını YENİ
sürümün CRD şemasıyla YENİDEN YAZMIŞ olabilir (bkz. §0'daki bulgu) — eski
sürüme dönüldüğünde bu alan YENİ şemaya göre yazılmış olarak KALIR ve eski
sürüm bunu OKUYAMAYABİLİR. **Bu yüzden Crossplane rollback'i, XRD'lerin
`etcd`/Raft snapshot'tan (bkz. `disaster-recovery.md`) geri yüklenmesini
gerektirebilir** — basit bir `helm rollback` YETMEYEBİLİR. Büyük bir
major-version sıçraması (1.x→2.x gibi) SONRASI geri alma, PRATİKTE bir
disaster-recovery senaryosuna dönüşür — bu yüzden §2.1'in test cluster'ı
adımı BU BİLEŞEN İÇİN OPSİYONEL DEĞİL, ZORUNLUDUR.

---

## 4. cert-manager

### Yükseltme

1. §2.1 (kind'de gerçek bir Issuer + Certificate ile test — bkz.
   `tests/e2e/kind-chain/run.sh`'in Vault Issuer adımları).
2. CRD'leri güncelle (`--set crds.enabled=true` veya `kubectl apply -f
   cert-manager.crds.yaml` — chart sürümüne göre değişir, `helm show
   values` ile teyit et).
3. `03-pki.sh --only cert-manager`.
4. Mevcut TÜM `Certificate` nesnelerinin `Ready=True` kaldığını doğrula:
   ```bash
   kubectl get certificates -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status'
   ```
5. Kısa ömürlü bir test sertifikasıyla (bkz. `05-observability.sh --only
   cert-alert-test`'in deseni) UÇTAN UCA yenileme test edilir.

### Geri alma

```bash
helm rollback cert-manager <önceki-revizyon> -n cert-manager
```

**Rollback riski:** CRD'ler `helm rollback` ile OTOMATİK geri ALINMAZ
(Helm'in CRD yönetim sınırlaması) — yeni sürümün CRD'si eski controller
tarafından anlaşılamayan bir alan eklediyse, eski controller o alanı
YOK SAYAR (genellikle güvenli) ama YENİ sürümün CRD'yi DEĞİŞTİRDİĞİ
(alan kaldırdığı) durumlar İSTİSNAİ ve tehlikelidir — CRD diff'i
yükseltmeden ÖNCE `kubectl diff` ile incelenmelidir.

---

## 5. ArgoCD

### Yükseltme

1. §2.1 gerekli DEĞİLDİR (ArgoCD, compositions/policy'leri ÇALIŞTIRMAZ,
   yalnızca senkronize eder) — bunun yerine ArgoCD'nin KENDİ
   Application'larının senkronizasyonunun bozulmadığını bir staging
   Application'ıyla test et.
2. `02-control-plane.sh --only argocd`.
3. `kubectl -n argocd get application -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status` — HİÇBİRİ `OutOfSync`/`Degraded`'a düşmemeli (`underlay-root`/`vault`/`loki`/`tempo`'nun KASITLI OutOfSync kalabileceği İSTİSNALAR HARİÇ — bkz. bu Application'ların kendi dosyalarındaki notlar).

### Geri alma

```bash
helm rollback argo-cd <önceki-revizyon> -n argocd
```

**Rollback riski:** Düşük — ArgoCD kendi state'ini (Application CR'ları)
Kubernetes'te tutar, rollback bunları SİLMEZ; yalnızca ArgoCD'nin KENDİ
pod'ları eski image'a döner ve senkronizasyona KALDIĞI YERDEN devam eder.

---

## 6. Kyverno

### Yükseltme

1. §2.1 — `kyverno test platform/policies/tests/` (tüm paket, hem
   `validation/` hem `security/`) YENİ sürümle YEŞİL olmalı — bu
   engagement genelinde (Faz 6b'de `match.any[].resources.operations`
   alanının kaldırılması gibi) Kyverno sürümleri arasında ŞEMA
   DEĞİŞİKLİKLERİ olduğu ZATEN GERÇEK CLI hatalarıyla kanıtlanmıştı — bu
   risk TEKRAR yaşanabilir.
2. `02-control-plane.sh --only kyverno`.
3. `kubectl get clusterpolicy -o custom-columns=NAME:.metadata.name,READY:.status.ready` — HİÇBİRİ `false` olmamalı.
4. **KRİTİK:** yeni sürüm sonrası mevcut trafiğe karşı bir "dry-run"
   penceresi: `validationFailureAction: Enforce` politikaları YENİ sürümde
   FARKLI davranıyor olabilir (örn. bir JMESPath fonksiyonunun anlamı
   değişmişse) — bu, GERÇEK trafiği YANLIŞLIKLA reddedebilir. Mümkünse
   yeni sürüm önce `--dry-run`/audit modunda 24 saat izlenir.

### Geri alma

```bash
helm rollback kyverno <önceki-revizyon> -n kyverno
```

**Rollback riski:** ClusterPolicy CRD'leri arasında sürüm farkı varsa
(nadiren) eski controller yeni CRD alanlarını görmezden gelir — genellikle
güvenli, ama Enforce politikalarının rollback SIRASINDA kısa bir süre
(webhook yeniden ayağa kalkana kadar) `Ignore`/`Fail` failurePolicy'sine
göre ya TÜM istekleri reddeder ya da TÜMÜNÜ kabul eder — bu pencere
mümkün olduğunca KISA tutulmalı (rolling update, `--wait`).

---

## 7. Ortak "asla yapma" listesi

- Birden fazla bileşeni AYNI ANDA yükseltmek (hangi değişikliğin hangi
  soruna yol açtığını AYIRT ETMEK imkânsızlaşır).
- §2.1'i (test cluster doğrulaması) "zaman kısıtı var" diye ATLAMAK — §0
  bunun BEDELİNİ zaten gösterdi.
- Bir CRD'yi `kubectl delete crd` ile ELLE silip yeniden oluşturmak
  (mevcut TÜM custom resource'ları SİLER — yalnızca `disaster-recovery.md`
  senaryosunda, bilinçli bir veri kaybı kararıyla yapılır).
- Rollback'i "büyük ihtimalle sorun yok" diyerek DENEMEDEN, yükseltmeyi
  üretimde bırakmak.
