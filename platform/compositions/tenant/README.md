# XTenant — Tenant self-servis soyutlaması

Faz 6. ADR-0001 Karar 2.1 + Karar 2.4. Bir `Tenant` claim'i uygulandığında,
Crossplane bunu bir `XTenant` composite kaynağına dönüştürür ve bu
composition **11 kaynak** üretir.

---

## Ürettiği kaynaklar

| # | Kaynak | Amaç |
|---|---|---|
| 1 | `Namespace` (`tenant-<teamName>-<environment>`) | 6 zorunlu etiketle (conventions §3.1+§3.2) |
| 2 | `Role` + `RoleBinding` | Keycloak `oidcGroup`'una bağlı namespace-scoped admin |
| 3 | `ResourceQuota` | `quotaTier`'a göre CPU/bellek/pod (bkz. aşağıdaki tier tablosu) |
| 4 | `LimitRange` | Konteyner başına varsayılan request/limit |
| 5 | `CiliumNetworkPolicy` × 2 | `tenant-default-deny` (her zaman) + `tenant-network-tier` (`networkTier`'a göre) |
| 6 | `ServiceAccount` | Tenant workload'larının kullanacağı kimlik |
| 7 | `Workspace` (provider-terraform) | Vault k8s-auth role + policy + PKI role — **tenant'a özel, izole** |
| 8 | `Issuer` (namespaced, cert-manager) | Vault PKI'nin tenant'a özel rolüne bağlı |
| 9 | `ConfigMap` (Faz 8) | Backstage catalog-info — bkz. `../../backstage/README.md` "Catalog-info otomasyonu" |

Kabul kriterindeki 6 tip (Namespace, RBAC, Quota, LimitRange, NetworkPolicy,
Issuer) bunların **hepsi K8s-native** olanlarıdır; ServiceAccount ve
Workspace görev metninde istenen ama kabul listesinde sayılmayan ek
kaynaklardır (yine de üretiliyor ve test ediliyor).

---

## Tier tablosu (conventions.md §4.1 ile senkron)

| `quotaTier` | CPU | Bellek | Pod |
|---|---|---|---|
| `small` | 4 | 8Gi | 10 |
| `medium` | 16 | 32Gi | 50 |
| `large` | 64 | 128Gi | 200 |

## `networkTier` (conventions.md §4.4 ile senkron)

| `networkTier` | Egress | Ingress |
|---|---|---|
| `isolated` | Yalnızca DNS | Yok |
| `open` | DNS + tenant-içi serbest | Tenant-içi serbest |
| `custom` | Yok (yalnızca default-deny) | Yok |

---

## Vault izolasyonu — iki tenant birbirinin domain'ine ERİŞEMEZ

Her tenant'ın **kendi** Vault PKI rolü vardır (`tenant-<teamName>`,
`pki-int-<environment>` mount'unda), `allowed_domains =
"tenant-<teamName>-<environment>.svc.cluster.local"` + `allow_subdomains =
true` ile kısıtlı. `tenant-acme` rolüyle `*.tenant-globex-dev...` için
sertifika istemek Vault'un KENDİSİ tarafından reddedilir — bu, cert-manager
veya Kubernetes RBAC'a değil, **PKI motorunun kendi domain kısıtına**
dayanan bir izolasyondur (bkz. `function.k` §6 ve `tests/e2e/`).

Bu rolleri provider-terraform (ADR-0001'in escape hatch'i) yönetir çünkü
Crossplane'in bir "provider-vault"ı yok — `function.k`'deki
`_vaultTerraformModule` HashiCorp'un resmi Terraform Vault provider'ını,
Vault'un KENDİ Kubernetes auth'uyla (statik kimlik bilgisi yok) çağırır.

---

## Neden `function.k` AYRI bir dosya, `composition.yaml`'a inline DEĞİL mi?

**İkisi de var, bilinçli olarak.** `function-kcl`'nin resmi/test edilebilir
biçimi KCL'i `Composition` YAML'ının içine gömmeyi ister (OCI/Git modülleri
production için önerilir ama bir registry gerektirir — bu repoda yok).
`function.k`:

1. **Canonical kaynaktır** — burayı düzenlersiniz.
2. **Cluster'sız hızlı test** sağlar: `kclvm_cli run function.k -D params=...`
   (bu PR'da fiilen bu şekilde, gerçek `kclvm_cli` 0.11.2 ile test edildi).
3. Teslim listesinin açıkça istediği bir dosyadır.

`composition.yaml`'daki gömülü kopya, `function.k` ile **elle senkron**
tutulur — `tests/verify-sync.sh` bu senkronun bozulmadığını doğrular
(drift varsa kırmızı verir).

---

## Test etme

```bash
# 1. Saf KCL mantığı (Docker/cluster GEREKMİYOR, saniyeler sürer)
kclvm_cli run function.k -D params='{"oxr":{"spec":{"teamName":"acme", ...}}}'

# 2. function.k ↔ composition.yaml senkron kontrolü
./tests/verify-sync.sh

# 3. Gerçek crossplane render (Docker GEREKİR — function-kcl + function-auto-ready
#    container'larını çalıştırır)
./tests/render-examples.sh
# Çıktı: platform/docs/examples-output/tenant-acme-{dev,prod}.rendered.yaml

# 4. Uçtan uca (GERÇEK CLUSTER gerekir — Faz 1-6 kurulu olmalı)
chainsaw test tests/e2e/
```

Bu PR'da 1-3 **fiilen çalıştırıldı ve yeşil**; 4 yalnızca `chainsaw lint` ve
`chainsaw test --no-cluster` ile yapısal olarak doğrulandı (gerçek bir
cluster bu ortamda yok — bkz. PLATFORM_CONTEXT.md).
