# tenant-requests

Ürün ekiplerinin altyapı taleplerini açtığı repo. **Bu repo, platform reposundan
ayrıdır ve canlıya alınırken ayrı bir Git reposuna taşınacaktır.**

> **Faz 8 güncellemesi:** `Tenant` (Faz 6) ve `PostgreSQLInstance` (Faz 7)
> şemaları kesinleşti. Bu README artık **gerçek, doğrulanmış** örnekler
> içeriyor — Faz 0'ın taslak `XTenant`/`environments:` modeli TERK EDİLDİ
> (gerçek implementasyon farklı alanlar kullandı, bkz. aşağıdaki not).

---

## Neden ayrı repo?

| Gerekçe | Açıklama |
|---|---|
| **Farklı yazma hakkı** | `platform` reposuna yalnızca platform ekibi yazar; buraya herkes PR açabilir. Ayrı repo, yanlışlıkla underlay değiştiren bir PR'ın var olamamasını sağlar. |
| **Farklı değişim hızı** | Tenant talepleri günlük, platform değişiklikleri haftalık gelir. Ayırmak, platform reposunun geçmişini okunabilir tutar. |
| **Denetim kaydı** | Bir tenant'ın kotasının ne zaman, kim tarafından, hangi gerekçeyle artırıldığı PR geçmişi olarak burada durur. |

Detay → platform reposu, ADR-0001 Bölüm 3.

---

## Yapı

```
.
├── README.md
├── CODEOWNERS                    # platform ekibi onayı zorunlu
├── .github/
│   ├── workflows/validate.yaml   # kubeconform + crossplane render + kyverno apply
│   └── scripts/
│       ├── xrd-to-jsonschema.py  # platform reposunun XRD'lerinden TAZE şema üretir
│       └── validate-claims.sh    # asıl doğrulama mantığı (yerel de çalıştırılabilir)
├── tenants/
│   └── <isim>.yaml               # Tenant claim'i — bkz. §"Tenant claim'i"
└── postgresql/
    └── <isim>.yaml               # PostgreSQLInstance claim'i — bkz. §"Postgres claim'i"
```

---

## Talep akışı

```
1. Backstage "Yeni Tenant Oluştur" / "Yeni Postgres İste" şablonu (veya elle PR)
2. tenants/<isim>.yaml veya postgresql/<isim>.yaml oluşur
3. CI: kubeconform (şema) + crossplane render (composition + KCL assert'ler)
       + kyverno apply (içerik-bazlı guardrail'ler) — sonuç PR'a yorum olarak yazılır
4. CODEOWNERS → platform ekibi onayı
5. merge → ApplicationSet (git generator) yeni/değişen claim'i tespit eder
   → ArgoCD Application'ı senkronize eder → Crossplane composition'ı açar
6. kubectl get tenant / kubectl get postgresqlinstance -n tenant-requests
```

**Merge sonrası elle yapılacak hiçbir adım yoktur.** Bir adım elle yapılıyorsa,
bu composition'da bir eksiklik olduğunun işaretidir. ArgoCD entegrasyonu:
`platform/control-plane/apps/06-tenant-requests-appset.yaml.tpl`.

---

## Tenant claim'i

```yaml
apiVersion: platform.internal/v1alpha1
kind: Tenant
metadata:
  name: acme-dev                 # dosya adıyla BİREBİR AYNI: tenants/acme-dev.yaml
  namespace: tenant-requests
spec:
  teamName: acme                 # conventions §1 — ^[a-z][a-z0-9-]{1,28}[a-z0-9]$
  costCenter: "CC-1042"          # ZORUNLU — ^CC-[0-9]{4}$
  environment: dev               # dev | staging | prod (kapalı küme)
  networkTier: isolated          # isolated | open | custom — bkz. conventions §4.4
  quotaTier: small               # small | medium | large — bkz. conventions §4.1
  oidcGroup: tenant-acme         # Keycloak grubu — RoleBinding subject'i
```

Gerçek, render edilmiş örnekler: [`../platform/compositions/tenant/examples/`](../platform/compositions/tenant/examples/).
Alan anlamları: `platform/docs/conventions.md`, composition mantığı:
`platform/compositions/tenant/README.md`.

## Postgres claim'i

```yaml
apiVersion: platform.internal/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: acme-orders-db
  namespace: tenant-requests
spec:
  size: medium                        # small | medium | large
  version: "16"                       # "14" | "15" | "16" | "17"
  highAvailability: true              # true ise size=small YASAK (min 2 replika)
  tenantRef: tenant-acme-dev          # KENDİ tenant namespace'iniz
```

Geliştirici runbook'u (hangi alanı doldurmalı, ne kadar sürer, bağlantı
bilgisine nereden ulaşılır): `platform/docs/runbooks/request-postgres.md`.

---

## Kurallar

| Kural | Zorlama |
|---|---|
| Bir PR = bir claim | Kod incelemesi |
| Dosya adı, `metadata.name` ile birebir aynı | Kod incelemesi (CI'da otomatik kontrol edilmiyor — henüz) |
| `teamName`/`costCenter`/`environment`/`networkTier`/`quotaTier` şemaya uygun | CI (kubeconform) |
| `highAvailability=true` + `size=small` yasak | CI (crossplane render → KCL assert) |
| `prod` ortamında `quotaTier=small` yasak | CI (crossplane render → XRD CEL) |
| Kim Tenant claim'i açabilir / `networkTier=custom` kimin seçebileceği | **CI'da DEĞİL** — gerçek admission zamanı (Kyverno 04/06) + CODEOWNERS incelemesi (bkz. aşağıdaki not) |
| Certificate yalnızca onaylı Issuer'a referans verebilir, PSS `restricted` | CI (kyverno apply, render edilmiş kaynaklara karşı) |
| Tenant/Postgres silme, PR açıklamasında **gerekçe ve veri imhası onayı** ister | Kod incelemesi |

> **Neden bazı kurallar "CI'da değil":** `restrict-tenant-claim-creation` ve
> `restrict-custom-network-tier` politikaları gerçek bir Keycloak OIDC
> kimliğine ihtiyaç duyar — CI'daki GitHub kullanıcı adı bir Kubernetes
> kimliği DEĞİLDİR. Bu ikisinin asıl uygulanma noktası PR'ı onaylayan
> CODEOWNERS (insan incelemesi) ve gerçek admission zamanıdır. CI'da simüle
> bir kimlikle "test etmek" yanıltıcı bir yeşil/kırmızı üretirdi — bu yüzden
> bilinçli olarak atlandı (`.github/scripts/validate-claims.sh` başlığı).

---

## Sık sorulanlar

**Daha fazla CPU istiyorum.** → `quotaTier`'ı yükseltin. Ara değer verilmez;
`large` yetmiyorsa platform ekibine yazın, tier tablosu gözden geçirilir.

**Dördüncü bir ortam istiyorum (`uat`).** → `dev|staging|prod` kapalı bir
kümedir. Ek izolasyon gerekiyorsa ayrı bir tenant açın.

**`networkTier: custom` seçebilir miyim?** → Yalnızca `platform-admins`
grubundaysanız. Sıradan bir istekte `isolated` veya `open` kullanın.

**Postgres'imi sildim, geri gelir mi?** → PITR saklama süresi içindeyse evet
(`quotaTier`'a göre 7/14/30 gün — `platform/docs/runbooks/request-postgres.md`
§8). Platform ekibiyle iletişime geçin.

**PR'ım CI'da kırmızı ama hata anlaşılmıyor.** → PR'daki otomatik yorumun
"hata detayları" bölümünü açın; `crossplane render` çıktısı orada tam olarak
görünür. Hâlâ anlaşılmıyorsa platform ekibine bildirin.
