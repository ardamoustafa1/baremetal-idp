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
