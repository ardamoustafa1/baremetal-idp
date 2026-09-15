# Örnek Tenant Talepleri

> **Faz 6 güncellemesi:** `XTenant` şeması artık kesinleşti ve gerçek
> örnekler yazıldı — ama **burada değil**. Gerçek, çalışan örnekler
> [`platform/compositions/tenant/examples/`](../compositions/tenant/examples/)
> altında yaşıyor (composition ile aynı yerde — `crossplane render`
> testlerinin göreceli yol referansları oradan geçiyor).
>
> Bu dizin, `tenant-requests` reposu Faz 7'de gerçekten kurulduğunda oraya
> kopyalanacak **referans kopyalar** için ayrılmış kalıyor.

## Faz 0'ın orijinal varsayımı neden değişti

Bu README başlangıçta "`tenant-medium`: dev + prod, HA veritabanı" gibi
**tek bir tenant talebinin birden fazla ortamı kapsadığı** bir model
varsayıyordu. Faz 6'da yazılan gerçek `Tenant` claim şeması bunun yerine
**tek bir `environment` alanı** (dev **veya** staging **veya** prod)
kullanıyor — yani çok ortamlı bir tenant, ortam başına **ayrı bir claim**
gerektiriyor (bkz. `tenant-acme-dev.yaml` + `tenant-acme-prod.yaml`, aynı
`teamName`, farklı `environment`).

Bu, mevcut örneklerdeki senaryo tablosuyla (tek dosya = çoklu ortam) ÇELİŞİYORDU;
gerçek implementasyon (bu görevin verdiği alan listesi: `teamName`,
`costCenter`, `environment` — TEKİL enum, `networkTier`, `quotaTier`,
`oidcGroup`) kesin olduğu için doküman ona göre düzeltildi.

## Gerçek örnekler

| Dosya | teamName | environment | quotaTier | networkTier |
|---|---|---|---|---|
| [`tenant-acme-dev.yaml`](../compositions/tenant/examples/tenant-acme-dev.yaml) | acme | dev | small | isolated |
| [`tenant-acme-prod.yaml`](../compositions/tenant/examples/tenant-acme-prod.yaml) | acme | prod | large | open |

Render edilmiş çıktı (gerçek `crossplane render` ile üretildi): [`docs/examples-output/`](../docs/examples-output/)

Tier tanımları → [`../docs/conventions.md`](../docs/conventions.md) §4.
