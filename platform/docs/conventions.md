# İsimlendirme ve Etiketleme Kuralları (Naming & Labeling Conventions)

> **Bu doküman normatiftir.** Buradaki kuralların ihlal edilemez olanları
> `platform/policies/kyverno/` altında Kyverno politikalarıyla **zorlanır**;
> kalanlar kod incelemesinde (code review) denetlenir.
>
> Anahtar kelimeler: **ZORUNLU** (uygulanır, ihlali reddedilir),
> **ÖNERİLEN** (sapma gerekçelendirilmeli), **İSTEĞE BAĞLI**.

---

## 1. Tenant adı (`<name>`)

Tenant adı, platformdaki **her şeyin** türetildiği birincil tanımlayıcıdır:
namespace, Harbor projesi, Keycloak grubu, Vault yolu, bucket adı hep bundan üretilir.

**ZORUNLU biçim:**

```
^[a-z][a-z0-9-]{1,28}[a-z0-9]$
```

| Kural | Gerekçe |
|---|---|
| Yalnızca küçük harf, rakam ve tire (`-`) | RFC 1123 DNS label; Harbor, Ceph bucket ve Keycloak grup adlarında da geçerli olmalı |
| Harfle başlar, harf veya rakamla biter | DNS label kısıtı |
| 3–30 karakter | `tenant-` öneki + ortam soneki eklendiğinde 63 karakter DNS sınırına sığmalı |
| Alt çizgi (`_`), nokta (`.`), büyük harf **yasak** | Ceph RGW bucket ve DNS adlarında geçersiz |
| Ayrılmış adlar yasak: `default`, `kube-*`, `platform`, `system`, `argocd`, `admin`, `vault` | Çakışma ve kimlik taklidi riski |

**ZORUNLU:** Tenant adı **ekip/ürün adıdır, ortam adı değildir.**
`payments` ✅ — `payments-prod` ❌ (ortam ayrı bir eksendir, bkz. §2).

---

## 2. Namespace isimlendirme

### 2.1 Tenant namespace'leri — ZORUNLU

```
tenant-<name>                  # tek ortamlı tenant
tenant-<name>-<environment>    # çok ortamlı tenant
```

**Örnekler:**

| Namespace | Anlam |
|---|---|
| `tenant-payments` | payments ekibi, tek ortam |
| `tenant-payments-dev` | payments ekibi, geliştirme |
| `tenant-payments-staging` | payments ekibi, hazırlık |
| `tenant-payments-prod` | payments ekibi, üretim |

**`tenant-` öneki neden ZORUNLU:**
1. Kyverno ve Cilium politikaları, tenant namespace'lerini **ad kalıbıyla**
   seçebilir (`tenant-*`); platform namespace'lerini yanlışlıkla kapsamaz.
2. `kubectl get ns` çıktısında tenant/platform ayrımı gözle anında görülür.
3. RBAC rol bağlamaları (RoleBinding) öneke göre üretilebilir.
4. OpenCost maliyet gruplaması, ad kalıbıyla ayrıştırılabilir.

**ZORUNLU:** Tenant namespace'leri **yalnızca** Crossplane `XTenant`
composition'ı tarafından yaratılır. Elle `kubectl create namespace tenant-*`
Kyverno tarafından reddedilir (`managed-by: crossplane` etiketi ve
Crossplane sahipliği doğrulanır).

### 2.2 Platform namespace'leri — ZORUNLU

Platform bileşenleri `tenant-` öneki **kullanmaz**; kendi konvansiyonel adlarını kullanır:

| Katman | Namespace |
|---|---|
| Bootstrap | `argocd` |
| Underlay | `kube-system` (Cilium), `metallb-system`, `rook-ceph` |
| PKI | `vault`, `cert-manager`, `external-secrets` |
| Control plane | `harbor`, `keycloak`, `cnpg-system`, `monitoring`, `opencost`, `velero` |
| Guardrails | `kyverno` |
| Composition | `crossplane-system` |
| Portal | `backstage` |

### 2.3 Ortam (environment) değerleri — ZORUNLU

Kapalı küme (closed set). Başka değer kabul edilmez:

```
dev | staging | prod
```

`test`, `uat`, `preprod`, `qa` gibi değerler kullanılmaz — üçten fazla ortam
ekseni, kota ve politika matrisini yönetilemez hale getirir. Ek izolasyon
gerekiyorsa ayrı bir tenant açılır.

---

## 3. Zorunlu etiketler (Labels)

### 3.1 Platform etiketleri — ZORUNLU

Her **tenant namespace'inde** ve o namespace altındaki her **workload'da**
(Deployment, StatefulSet, DaemonSet, CronJob, Job) aşağıdaki 5 etiket bulunmalıdır.
Kyverno `validate` ile zorlanır; workload'lara namespace'ten `mutate` ile
miras alınır.

| Etiket | Zorunlu | Değer biçimi | Örnek | Amaç |
|---|---|---|---|---|
| `platform.internal/cost-center` | **ZORUNLU** | `^CC-[0-9]{4}$` | `CC-1042` | Maliyet atfı (OpenCost chargeback) |
| `platform.internal/owner` | **ZORUNLU** | geçerli e-posta veya `team-<name>` | `team-payments` | Sahiplik, olay (incident) yönlendirme |
| `platform.internal/environment` | **ZORUNLU** | `dev\|staging\|prod` | `prod` | Politika sertliği, uyarı yönlendirme |
| `platform.internal/managed-by` | **ZORUNLU** | `crossplane` (sabit) | `crossplane` | Elle yaratılmış kaynakları ayırt etmek |
| `platform.internal/tenant` | **ZORUNLU** | tenant adı (§1) | `payments` | Namespace adından bağımsız tenant kimliği |

**Neden `platform.internal/` önek (prefix) alanı:**
Öneksiz `owner`/`environment` gibi etiketler, Helm chart'ları ve üçüncü parti
operatörlerin kendi etiketleriyle çakışabilir. Kendi alan adımızı kullanmak
sahipliği açık kılar ve Kyverno seçicilerini kesin yapar.

**`managed-by: crossplane` neden ZORUNLU:**
Bu etiket olmadan yaratılan bir tenant namespace'i, elle yaratılmış demektir.
Kyverno bunu reddeder. Bu, "kümedeki her tenant kaynağının Git'te bir
karşılığı vardır" garantisinin **teknik olarak zorlanan** halidir.

### 3.2 Tier etiketi — ZORUNLU (yalnızca namespace düzeyinde)

| Etiket | Değer biçimi | Örnek |
|---|---|---|
| `platform.internal/tier` | `small\|medium\|large` | `medium` |

### 3.3 Standart Kubernetes etiketleri — ÖNERİLEN

Tenant workload'ları için `app.kubernetes.io/` standart etiket seti önerilir;
Backstage katalog eşleştirmesi ve Grafana dashboard'ları bunlara dayanır:

```
app.kubernetes.io/name          # örn. checkout-api
app.kubernetes.io/instance      # örn. checkout-api-prod
app.kubernetes.io/version       # örn. 1.24.0
app.kubernetes.io/component     # örn. api | worker | frontend
app.kubernetes.io/part-of       # örn. payments
app.kubernetes.io/managed-by    # örn. argocd | helm
```

### 3.4 Annotation'lar — ÖNERİLEN

Etiketler **seçilebilir/filtrelenebilir** olmalıdır; uzun ve serbest metin
içerikler annotation'a gider (etiket değerleri 63 karakterle sınırlıdır).

| Annotation | Amaç |
|---|---|
| `platform.internal/description` | Tenant/uygulama tek satırlık açıklaması |
| `platform.internal/slack-channel` | Olay durumunda ulaşılacak kanal |
| `platform.internal/runbook-url` | Runbook bağlantısı |
| `platform.internal/request-pr` | Bu kaynağı yaratan `tenant-requests` PR bağlantısı |

---

## 4. Tier isimlendirmeleri ve kaynak profilleri

Tier, tenant'ın **kaynak bütçesinin** adıdır. Tenant, ham CPU/bellek sayısı
istemez; bir tier seçer. Değerler `compositions/kcl/` içinde **tek bir yerde**
tanımlıdır ve composition tarafından `ResourceQuota` + `LimitRange`'e açılır.

### 4.1 Tier tanımları — ZORUNLU (kapalı küme)

> **Faz 6 güncellemesi:** Bu tablo, `XTenant` composition'ının (Faz 6,
> `compositions/tenant/function.k`) fiilen ürettiği CPU/bellek/pod
> değerleriyle eşleşecek şekilde güncellendi. Önceki tablo (2/4 CPU vb.)
> Faz 6'dan önce yazılmış bir taslaktı ve hiçbir composition tarafından
> uygulanmıyordu; gerçek implementasyon yazılırken bu görev BAŞKA sayılar
> (4/16/64 CPU) verdi. **`function.k` artık tek doğruluk kaynağıdır** —
> bu tablo onunla senkron tutulur, tersi değil.

| | `small` | `medium` | `large` |
|---|---|---|---|
| **Hedef kullanım** | PoC, iç araç, dev ortamı | Üretimde normal servis | Yüksek hacimli / kritik servis |
| **CPU — requests = limits** | 4 | 16 | 64 |
| **Bellek — requests = limits** | 8 Gi | 32 Gi | 128 Gi |
| **Maks. pod sayısı** | 10 | 50 | 200 |
| **Blok depolama (Ceph RBD)** | 20 Gi | 100 Gi | 500 Gi |
| **Paylaşımlı depolama (CephFS)** | — | 50 Gi | 250 Gi |
| **Obje depolama (RGW)** | — | 100 Gi | 1 Ti |
| **Maks. Service (LoadBalancer)** | 0 | 1 | 3 |
| **Maks. PVC sayısı** | 5 | 20 | 60 |
| **Veritabanı (CNPG) — örnek sayısı** | 1 (HA yok) | 3 (HA) | 3 (HA) + ayrılmış node |
| **Yedek saklama (Velero)** | 7 gün | 30 gün | 90 gün |
| **Varsayılan LimitRange (konteyner)** | 100m / 128Mi (istek) — 500m / 512Mi (limit) | aynı | aynı |

> Depolama/PVC/LB/CNPG/Velero sütunları henüz hiçbir composition tarafından
> ÜRETİLMİYOR (Faz 6'nın `XTenant`'ı yalnızca CPU/bellek/pod'u
> ResourceQuota+LimitRange'e açıyor — bkz. görev kapsamı). Bu sütunlar
> `XDatabase`/`XBucket` compositionları (gelecek fazlar) yazıldığında
> gerçek bir uygulamaya kavuşacak; o zamana kadar bu tablodaki değerler
> **planlanan** hedeftir, zorlanan değil.
>
> Değişiklik yalnızca `compositions/tenant/function.k` içinde yapılır —
> hiçbir yerde elle tekrarlanmaz.

### 4.2 Tier kuralları

- **ZORUNLU:** Her `XTenant` bir tier belirtir. Varsayılan yoktur — açık seçim zorunludur.
- **ZORUNLU:** `prod` ortamında `small` tier kullanılamaz (HA yok, yedek 7 gün).
  Kyverno ile zorlanır.
- **ZORUNLU:** Tier yükseltme/düşürme, `tenant-requests` reposunda bir PR ile yapılır.
  Düşürme (downgrade), mevcut kullanım yeni kotanın altındaysa reddedilir.
- **ÖNERİLEN:** Ara değer icat edilmez. `large` yetmiyorsa bu, tier tablosunun
  gözden geçirilmesi (veya `xlarge` eklenmesi) için bir sinyaldir — tenant'a
  özel istisna verilmez.

### 4.3 Neden t-shirt tier'ları, serbest kaynak isteği değil?

1. **Kapasite planlaması mümkün olur.** 40 tenant × serbest istek = planlanamaz.
   40 tenant × 3 tier = toplanabilir bir tablo.
2. **Pazarlık ortadan kalkar.** "Bana 12 CPU ver" tartışmasını "hangi tier?"
   sorusu kapatır.
3. **Maliyet öngörülebilir olur.** Her tier'ın bir aylık maliyeti hesaplanıp
   OpenCost ile doğrulanabilir; geri ödeme (chargeback) basitleşir.
4. **Değişiklik tek yerden yayılır.** Tier tanımı değişince tüm tenant'lar
   uzlaşma (reconciliation) ile güncellenir.

### 4.4 Ağ katmanı (`networkTier`) — ZORUNLU (kapalı küme, Faz 6)

`XTenant`'ın (compositions/tenant/) her tenant için ürettiği
`CiliumNetworkPolicy` çiftinin ikincisi (`tenant-network-tier`), bu alana
göre parametrik izin listesi üretir. `tenant-default-deny` (birinci
politika) HER ZAMAN, ortam/tier fark etmeksizin uygulanır.

| Değer | Egress | Ingress | Kullanım |
|---|---|---|---|
| `isolated` | Yalnızca kube-dns (DNS çözümlemesi) | Yok | Varsayılan/en kısıtlı — dış bağımlılığı olmayan iç araçlar |
| `open` | DNS + aynı tenant namespace'i içi serbest | Aynı tenant namespace'i içi serbest | Birden fazla servisi olan, kendi içinde konuşan tenant'lar |
| `custom` | Yok (default-deny dışında hiçbir kural) | Yok | Tenant, kendi `CiliumNetworkPolicy`'sini elle ekler (bkz. `policies/generation/`'ın gelecekteki tenant-özel istisna mekanizması) |

**ZORUNLU:** `custom` seçildiğinde composition **hiçbir ek izin
üretmez** — namespace, `tenant-default-deny` ile tamamen kapalı kalır ve
tenant, kendi PR'ında ek `CiliumNetworkPolicy` ekleyene kadar dış/iç hiçbir
trafiğe izin verilmez. Bu bilinçlidir: `custom`, "ben ne istediğimi
biliyorum" anlamına gelir, platformun varsayım yapmasını değil.

---

## 5. Diğer kaynakların isimlendirilmesi

Hepsi tenant adından **deterministik olarak türetilir**; composition üretir,
elle yazılmaz.

| Kaynak | Kalıp | Örnek (`payments`, `prod`) |
|---|---|---|
| Namespace | `tenant-<name>[-<env>]` | `tenant-payments-prod` |
| Harbor projesi | `<name>` | `payments` |
| Harbor robot hesabı | `robot$<name>+ci` | `robot$payments+ci` |
| Keycloak grubu | `tenant-<name>` | `tenant-payments` |
| Keycloak client | `<name>-<env>` | `payments-prod` |
| Vault KV yolu | `kv/tenants/<name>/<env>/*` | `kv/tenants/payments/prod/db` |
| Vault PKI rolü | `tenant-<name>` | `tenant-payments` |
| Vault policy | `tenant-<name>-<env>` | `tenant-payments-prod` |
| Ceph RGW bucket | `<name>-<env>` | `payments-prod` |
| CNPG Cluster | `<name>-db` | `payments-db` |
| StorageClass (blok) | `ceph-block-<tier-sınıfı>` | `ceph-block-replicated` |
| StorageClass (paylaşımlı) | `ceph-filesystem` | `ceph-filesystem` |
| DNS / ingress ana adı | `<app>.<name>.<env>.apps.<domain>` | `checkout.payments.prod.apps.example.internal` |
| Cilium politika adı | `<name>-<amaç>` | `payments-default-deny` |
| ArgoCD Application | `tenant-<name>-<env>` | `tenant-payments-prod` |
| Velero Schedule | `tenant-<name>-<env>-daily` | `tenant-payments-prod-daily` |
| ResourceQuota | `tenant-quota` (ns içinde sabit) | `tenant-quota` |
| LimitRange | `tenant-limits` (ns içinde sabit) | `tenant-limits` |
| RBAC Role/RoleBinding (ns içinde) | `tenant-admin` / `tenant-admin-binding` (sabit) | `tenant-admin` |
| ServiceAccount (tenant workload) | `tenant-workload` (ns içinde sabit) | `tenant-workload` |
| cert-manager Issuer (namespaced) | `tenant-issuer` (ns içinde sabit) | `tenant-issuer` |
| CiliumNetworkPolicy (tenant) | `tenant-default-deny` + `tenant-network-tier` (sabit) | `tenant-default-deny` |
| provider-terraform Workspace | `tenant-<name>-<env>-vault` | `tenant-payments-prod-vault` |

**ZORUNLU:** Bu kalıplar `compositions/kcl/naming.k` içinde **tek bir fonksiyon
kümesi** olarak kodlanır. Hiçbir composition kendi string birleştirmesini yapmaz.

---

## 6. Git ve dosya isimlendirme

| Konu | Kural |
|---|---|
| `tenant-requests` dosya adı | `tenants/<name>.yaml` — tenant adıyla birebir aynı |
| ADR dosya adı | `docs/adr/NNNN-kisa-baslik.md`, 4 haneli sıra numarası |
| Branch adı | `<tip>/<kisa-aciklama>` — tip: `feat`, `fix`, `docs`, `chore` |
| Commit mesajı | Conventional Commits: `feat(underlay): cilium 1.16 yükseltmesi` |
| Kubernetes YAML dosya adı | `<kind-kucuk-harf>-<ad>.yaml` (örn. `deployment-checkout-api.yaml`) |

---

## 7. Kuralların zorlanma haritası

| Kural | Zorlama mekanizması | Konum |
|---|---|---|
| Namespace ad kalıbı | Kyverno `validate` | `policies/validation/` |
| 5 zorunlu etiket | Kyverno `validate` | `policies/validation/` |
| Etiketlerin workload'lara mirası | Kyverno `mutate` | `policies/mutation/` |
| `managed-by: crossplane` | Kyverno `validate` | `policies/validation/` |
| Tier kapalı kümesi | KCL şeması (CI'da) + XRD OpenAPI enum | `compositions/` |
| `prod` + `small` yasağı | Kyverno `validate` | `policies/validation/` |
| Kaynak adı türetme | KCL `naming.k` | `compositions/kcl/` |
| Varsayılan `default-deny` ağ politikası | Kyverno `generate` | `policies/generation/` |
| Tenant adı ayrılmış kelime kontrolü | XRD OpenAPI pattern + KCL | `compositions/xrds/` |
