# kind tabanlı uçtan uca zincir testi

Faz 11, görev madde 3: "Tenant claim → Postgres claim → bağlantı → cert
doğrulama tam zincirini gerçek (veya kind tabanlı) bir test cluster'ında
otomatik çalıştır."

## Bu testte GERÇEKTEN kanıtlanan zincir

```
Tenant claim
  → (Crossplane + function-kcl, GERÇEK crossplane 2.4.0 reconciler)
  → Namespace + RBAC + ResourceQuota/LimitRange + ServiceAccount
  → Issuer (cert-manager, Vault kubernetes-auth backend — GERÇEK Vault HA/Raft'a karşı)
  → Postgres claim
  → CNPG Cluster (gerçek, healthy)
  → bağlantı Secret'ı (`<name>-app`, gerçek kullanıcı adı/parola)
  → Certificate (AYNI tenant Issuer'ından imzalanmış)
  → openssl verify: leaf → Vault intermediate → Vault root : OK
```

Bu, bu mühendislik sürecinde (Faz 0'dan beri) **crossplane'in canlı bir
cluster'a karşı GERÇEKTEN reconcile ettiği İLK sefer**dir — önceki tüm
fazlar yalnızca `crossplane render` (statik, tek seferlik render) kullandı.
Bu fark ÖNEMLİDİR: render, Crossplane'in ÇALIŞMA ZAMANI RBAC/CRD/reconcile
davranışını test ETMEZ — ve bu test, tam olarak bunları test ederek üç
GERÇEK, önceden bilinmeyen hata buldu (bkz. aşağıdaki "Bulunan ve düzeltilen
hatalar").

## Bulunan ve düzeltilen hatalar (bu test sırasında)

1. **Kritik: `versions.env`'in pinlediği Crossplane 1.18.0, bu repo'nun
   composition tasarımıyla (namespaced kaynaklar + cluster-scoped v1 XRD)
   ÇALIŞMIYOR** — `resourceRefs[].namespace: field not declared in schema`
   hatasıyla HER composite kaynak REDDEDİLİYORDU. Crossplane 2.4.0 bu
   sorunu ÇÖZÜYOR. `versions.env` güncellendi (bkz. PLATFORM_CONTEXT.md).
2. **`platform/compositions/postgresql/function.k`**: `certificates.
   serverCASecretName` alanı CNPG'nin GERÇEK CRD şemasında YOK (doğrusu:
   `serverCASecret`) — düzeltildi, `render-examples.sh --check` ile
   yeniden doğrulandı.
3. **`platform/compositions/tenant/function.k`**: `tenant-issuer`,
   Vault'a `serviceAccountRef: {name: "cert-manager"}` ile auth olmaya
   çalışıyordu ama composition bu adda bir ServiceAccount HİÇ ÜRETMİYORDU
   — Issuer HİÇBİR ZAMAN Ready olamazdı (gerçek/bare-metal bir kurulumda
   da). `certManagerServiceAccount`/`certManagerTokenRequestRole`/
   `RoleBinding` eklendi.

Üçü de bu test SAYESİNDE keşfedildi — hiçbiri önceki fazların statik
(`crossplane render`, `kclvm_cli`, `kyverno test`) doğrulamalarıyla
YAKALANAMAZDI çünkü hiçbiri GERÇEK bir apiserver'a karşı reconcile
denemedi.

## Kapsam dışı bırakılanlar (kind'in sağlayamadığı bağımlılıklar)

`run.sh`, GERÇEK `composition.yaml` dosyalarını kullanır ama
`strip_unsupported_resources.py` ile (yalnızca ÇALIŞMA ZAMANI geçici bir
kopya üzerinde, repo dosyalarını DEĞİŞTİRMEDEN) şu kaynakları `items`
listesinden çıkarır:

| Composition | Çıkarılan kaynak | Neden |
|---|---|---|
| Tenant | `defaultDenyPolicy`, `tierNetworkPolicy` | `CiliumNetworkPolicy` CRD'si gerekir — kind kendi CNI'sini (kindnet) kullanır, Cilium kurulu değil |
| Tenant | `vaultWorkspace` | `tf.upbound.io` (provider-terraform) gerekir — Terraform provider'ı Crossplane'e kurulmadı; bunun yerine `run.sh`, Terraform'un yapacağı Vault PKI role/policy kurulumunu DOĞRUDAN `vault write` ile taklit eder |
| Postgres | `backupBucket`, `scheduledBackup` | Rook-Ceph OBC gerekir |
| Postgres | `networkPolicy` | Cilium (yukarıdaki ile aynı) |
| Postgres | `serviceMonitor` | kube-prometheus-stack CRD'si gerekir |
| Postgres | `secretStore`, `pushSecret`, `externalSecret` | ESO + Vault `kv/` mount'u gerekir |

**Bu kaynaklar bu testte doğrulanmadı** — bunlar için gerçek doğrulama
`platform/compositions/{tenant,postgresql}/tests/e2e/` altındaki chainsaw
testleridir (Faz 1-3/6/6b/7 kurulu, GERÇEK bare-metal/tam platform
cluster'ı gerektirir — bu görevde YİNE çalıştırılamadı, aynı kısıtlama
devam ediyor).

## Yerel çalıştırma

```bash
kind create cluster --name platform-e2e --wait 120s
bash tests/e2e/kind-chain/run.sh
kind delete cluster --name platform-e2e
```

CI'da: `.github/workflows/platform-ci.yaml` → `e2e-chain-test` job'ı.

## Süre

Yerel bir geliştirme makinesinde tüm zincirin kurulumu (cert-manager +
CNPG + Vault + Crossplane + init/unseal/PKI + iki claim + CNPG cluster'ın
healthy olması) yaklaşık **5-8 dakika** sürer (CNPG cluster'ının
`Running`'den `healthy`'e geçişi en uzun adımdır).
