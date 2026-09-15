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

Her tenant'ın **kendi** Vault PKI rolü vardır (`tenant-<nsName>`,
`pki-int-<environment>` mount'unda), `allowed_domains =
"<nsName>.svc.cluster.local"` + `allow_subdomains = true` ile kısıtlı.
`tenant-acme` rolüyle `*.tenant-globex-dev...` için sertifika istemek
Vault'un KENDİSİ tarafından reddedilir — bu, **PKI motorunun kendi domain
kısıtına** dayanan, bağımsız bir izolasyon katmanıdır.

**AMA bu TEK BAŞINA yeterli DEĞİLDİR** (Faz 12j, code review #8'de bulunan
gerçek boşluk): domain kısıtı yalnızca "hangi PKI ROLÜ hangi domain'i
imzalayabilir" sorusunu cevaplar — "KİM o PKI rolünü ÇAĞIRABİLİR" sorusunu
DEĞİL. ÖNCEDEN cert-manager Issuer'ı TÜM tenant'ların PAYLAŞTIĞI TEK bir
Vault auth role'ü (`cert-manager`) kullanıyordu ve o role'ün policy'si
`pki-int-<env>/sign/tenant-*` GLOB'una sahipti — yani BİR tenant'ın kimliği
(kendi namespace'indeki `cert-manager` ServiceAccount'u), Vault API'sine
DOĞRUDAN bir çağrı yaparak (cert-manager'ın normal Issuer/Certificate CRD
akışının DIŞINDA) `pki-int-<env>/sign/tenant-globex-dev`'i çağırabilir ve
GEÇERLİ bir `*.tenant-globex-dev.svc.cluster.local` sertifikası ALABİLİRDİ
— globex'in KENDİ rolü globex'in KENDİ domain'i için sertifika üretmeye
YETKİLİYDİ, sorun domain kısıtında değil, "kim bu rolü çağırabilir"
kısıtındaydı.

**ÇÖZÜM:** her tenant artık KENDİ Vault auth role'ünü
(`cert-manager-tenant-<nsName>`) VE KENDİ policy'sini (`cert-manager-
tenant-<nsName>`, YALNIZCA `pki-int-<env>/sign/tenant-<nsName>`'a erişimi
olan) kullanıyor — `_vaultBootstrapScript` tarafından `tenant-<nsName>`/
`eso-tenant-<nsName>` İLE AYNI desende üretilir. Paylaşılan `cert-manager`
role'ü artık YALNIZCA `cert-manager` namespace'indeki (ClusterIssuer'lar
için) SA'yı kapsar.

**Negatif test (bu görevde canlı bir Vault olmadığı için ÇALIŞTIRILAMADI —
gerçek bir cluster'da doğrulanmalı):**

```bash
# acme tenant'ının cert-manager SA'sıyla auth olup globex'in rolünü
# imzalamaya ÇALIŞ — "permission denied" BEKLENİR:
kubectl -n tenant-acme-dev exec deploy/some-debug-pod -- sh -c '
  TOKEN=$(vault write -field=token auth/kubernetes/login \
    role=cert-manager-tenant-tenant-acme-dev \
    jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)
  VAULT_TOKEN=$TOKEN vault write pki-int-dev/sign/tenant-tenant-globex-dev \
    common_name=evil.tenant-globex-dev.svc.cluster.local
  # beklenen: "permission denied" (403) — acme'nin role'ü globex'in
  # PKI yolunu HİÇ İÇERMEZ
'
```

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
