# L5 — Guardrails (Kyverno)

`conventions.md`'deki normatif kuralların **teknik olarak zorlanan** hali.
Politika olmayan bir kural, kural değil temennidir.

| Dizin | Politika tipi | Örnek |
|---|---|---|
| `rbac/` | Düz Kubernetes RBAC (ClusterRole/ClusterRoleBinding) | Tenant claim'i kimin açabileceği — Kyverno'nun ANALOG kontrolüyle birlikte çalışır |
| `validation/` | `validate` — ihlali reddeder | (a-c) Faz 2 taban hijyeni; (04-08) Tenant guardrail'leri |
| `mutation/` | `mutate` — eksiği tamamlar | Namespace etiketlerini workload'lara miras bırakma; varsayılan `securityContext` — planlandı |
| `generation/` | `generate` — yan kaynak üretir | Tenant-özel istisna mekanizmaları — planlandı |
| `tests/` | `kyverno test` fixture'ları | Her `validation/` politikası için en az bir "izin verilmeli" + bir "reddedilmeli" senaryosu |

Kural → politika eşlemesi: [`../docs/conventions.md`](../docs/conventions.md) Bölüm 7.

---

## Politika yaşam döngüsü — İKİ FARKLI KURAL, BİLİNÇLİ AYRIM

**Genel kural (taban hijyen politikaları, 01-03):** yeni politika önce
`Audit` modunda yayınlanır, mevcut ihlaller raporlanır/düzeltilir, ardından
`Enforce`'a alınır. **Faz 2'de yazılan 3 politika hâlâ `Audit`**'te —
Enforce'a geçiş ayrı bir PR.

**İstisna (Tenant guardrail'leri, 04-08):** bu 5 politika **doğrudan
`Enforce` ile yayınlandı**, Audit dönemi YOK. Gerekçe: bunlar taban hijyen
değil, Tenant self-servis akışının **güvenlik sınırının kendisi**. Bir
"kim Tenant claim'i açabilir" veya "quotaTier bypass" kontrolünü Audit
modunda bırakmak, tam olarak önlemeye çalıştığı şeyi (yetkisiz erişim,
kota aşımı) burn-in penceresi boyunca SERBEST BIRAKMAK demektir — hijyen
politikalarının aksine, ihlal burada "sonra düzeltilecek bir uyarı" değil,
"şimdi engellenmesi gereken bir güvenlik olayı"dır.

---

## Faz 2'de kurulan 3 başlangıç ClusterPolicy'si (Audit)

| Politika | Kapsam | Muaf tutulan namespace'ler |
|---|---|---|
| `require-pod-resources` | Her container'da cpu/memory requests+limits | `kube-system`, `kube-node-lease`, `kube-public` |
| `disallow-privileged-hostnetwork` | `privileged: true` ve `hostNetwork: true` yasağı | `kube-system`, `rook-ceph`, `metallb-system` (host-level daemon'lar) |
| `require-tenant-labels` | `tenant-*` namespace'lerinde cost-center/owner/environment | Yalnızca `tenant-*` adına eşleşenler kapsanır |

---

## Tenant guardrail'leri (04-08, hepsi Enforce)

| # | Politika | Neyi engeller | RBAC eşliği |
|---|---|---|---|
| 04 | `restrict-tenant-claim-creation` | `platform-tenant-requesters`/`platform-admins` grubu dışındaki (ve ArgoCD dışındaki) herkesin yeni bir `Tenant` claim'i açması | `rbac/tenant-claim-rbac.yaml` (ClusterRole+ClusterRoleBinding, aynı grup) |
| 05 | `protect-tenant-resourcequota` | `tenant-quota`/`tenant-limits` nesnelerinin Crossplane (provider-kubernetes) DIŞINDA biri tarafından elle büyütülmesi — quotaTier bypass | — (username prefix kontrolü, RBAC'a ek ihtiyaç yok) |
| 06 | `restrict-custom-network-tier` | `networkTier=custom`'ın `platform-admins` DIŞINDA biri tarafından seçilmesi | — |
| 07 | `restrict-certificate-issuer` | Bir `Certificate`'ın onaylı 3 `ClusterIssuer` + 1 namespaced `Issuer` (`tenant-issuer`) DIŞINDA bir Issuer'a referans vermesi | — |
| 08 | `require-pss-restricted` | Pod Security Standards `restricted` etiketleri olmayan bir `tenant-*` namespace'i | — |

**Bağımlılık:** 04/06, `request.userInfo.groups`'un dolu olmasını varsayar —
bu, K8s API server'ın OIDC entegrasyonuna bağımlıdır ve **henüz hiçbir
fazda kurulmadı** (bkz. PLATFORM_CONTEXT.md teknik borç #17). Bu iki
politika kurulduğunda, OIDC olmadan gelen HER istek `request.userInfo.groups`
boş göreceği için **her zaman reddedilir** — bu, "OIDC kurulana kadar
kimse Tenant açamaz" anlamına gelir ve KASITLI OLARAK bu şekilde bırakıldı
(fail-closed, fail-open değil).

**08'in Faz 6 composition'ına geri etkisi:** `compositions/tenant/function.k`
bu görev kapsamında güncellendi — artık her ürettiği Namespace'e 3 PSS
etiketini otomatik ekliyor. Bu güncelleme olmadan 08 numaralı politika,
composition'ın ÜRETTİĞİ her namespace'i anında reddederdi.

---

## Testleri çalıştırmak

```bash
# kyverno CLI kurulu değilse:  brew install kyverno

# Tüm politikalar, tek komut, tüm alt dizinler otomatik keşfedilir:
kyverno test platform/policies/tests/
# → 33 test, hepsi PASS (8 politika × senaryo başına 1+ test)

# Tek bir politika:
kyverno test platform/policies/tests/restrict-tenant-claim-creation
```

**Kullanıcı kimliği gerektiren politikalar (04, 05, 06) NASIL test edilir:**
`kyverno-test.yaml`'ın global `userinfo:` alanı tek bir simüle kimlik
tanımlar (`apiVersion: cli.kyverno.io/v1alpha1, kind: UserInfo`,
`userInfo: {username, groups}`) — **per-result override YOKTUR** (CLI bunu
reddeder). Bu yüzden "yetkili kullanıcı" ve "yetkisiz kullanıcı"
senaryoları **ayrı alt dizinlerde** (`allowed/`, `denied/` vb.) durur, her
biri kendi `userinfo.yaml`'ıyla. Bu şema, dokümantasyonda AÇIKÇA
yazmıyordu — CLI'nin `unknown field` hatalarını ardışık deneyerek
(`subjects` → `subject` → `userInfo: {username, groups}`) gerçek şema
ortaya çıkarıldı.

Her test paketi en az bir "izin verilmeli" ve bir "reddedilmeli" senaryosu
içerir (görev kabul kriteri) — 33 testin tamamı **gerçek `kyverno` CLI
1.19.1 ile yeşil** (bkz. PLATFORM_CONTEXT.md Faz günlüğü).
