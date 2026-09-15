# Crossplane v2 — Tenant API çalışma zamanı

ADR-0001 Karar 2.1 (Crossplane, Terraform değil) ve Karar 2.4 (KCL composition
function). Bu dizin, Faz 6'da yazılacak gerçek `XTenant` composition'ının
**altyapısını** kurar — composition'ın kendisi burada değil,
[`platform/compositions/`](../../compositions/) içinde.

---

## Bileşenler

| Manifest | Ne kurar |
|---|---|
| `values.yaml` | Crossplane core Helm chart değerleri |
| `resources/providers.yaml` | `provider-kubernetes`, `provider-helm`, `provider-terraform` (escape hatch) + `DeploymentRuntimeConfig` |
| `resources/functions.yaml` | `function-kcl` — composition mantığının çalıştığı runtime |
| `resources/providerconfigs.yaml` | Her provider için kimlik doğrulama — **hepsi in-cluster, statik kimlik bilgisi yok** |

---

## KCL composition function'ı nasıl aktifleştiriyoruz

### 1. Ön koşul: Composition Functions (pipeline mode)

Crossplane 1.14+ itibarıyla Composition Functions **GA** ve varsayılan olarak
açıktır — `CROSSPLANE_CHART_VERSION=1.18.0` bunu karşılar, özel bir
feature-gate bayrağı **gerekmez**. Doğrulama:

```bash
kubectl -n crossplane-system get deploy crossplane -o jsonpath='{.spec.template.spec.containers[0].args}'
# Composition Functions'a özel bir --enable-* bayrağı GÖRMEYİ BEKLEMİYORUZ —
# GA olduğu için yok. "--enable-usages" (values.yaml'da ayarlı) görünmeli.
```

### 2. `function-kcl` paketinin kurulması

`resources/functions.yaml` bir `Function` CR'ı uygular. Bu, Crossplane'e
"bu OCI paketini çek ve bir composition function olarak çalıştır" der —
tıpkı bir `Provider` gibi, kendi pod'unda (gRPC sunucusu) çalışır.

```bash
kubectl get functions.pkg.crossplane.io
# NAME            INSTALLED   HEALTHY   PACKAGE
# function-kcl    True        True      xpkg.upbound.io/.../function-kcl:v0.10.0

kubectl -n crossplane-system get pods -l pkg.crossplane.io/function=function-kcl
```

### 3. Bir Composition'da KCL adımını çağırmak

`XTenant` composition'ı (Faz 6) `mode: Pipeline` kullanır ve pipeline'ın bir
adımı `function-kcl`'ye işaret eder. **Şema:**

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xtenant.platform.internal
spec:
  compositeTypeRef:
    apiVersion: platform.internal/v1alpha1
    kind: XTenant
  mode: Pipeline
  pipeline:
    - step: render-with-kcl
      functionRef:
        name: function-kcl
      input:
        apiVersion: krm.kcl.dev/v1alpha1
        kind: KCLInput
        spec:
          # Seçenek A: inline kaynak (küçük/tek dosyalık mantık)
          source: |
            oxr = option("params").oxr
            items = [
              {
                apiVersion = "v1"
                kind = "Namespace"
                metadata.name = "tenant-${oxr.spec.name}"
              }
            ]
          # Seçenek B (ÖNERİLEN — compositions/kcl/ modülleri için):
          # source: platform/compositions/kcl/tenant.k
          # (function-kcl, ConfigMap veya OCI olarak paketlenmiş KCL modüllerini
          #  de destekler; compositions/README.md'deki naming.k/tiers.k/labels.k
          #  modülleri bu şekilde import edilecek.)
    - step: automatically-detect-ready
      functionRef:
        name: function-auto-ready   # Crossplane'in dahili "ready" function'ı
```

> Bu README **wiring'i** belgeler — gerçek `XTenant` composition'ı ve KCL
> modülleri (`naming.k`, `tiers.k`, `labels.k`, `tenant.k`) Faz 6 kapsamındadır.

### 4. Doğrulama

```bash
kubectl get providers.pkg.crossplane.io
kubectl get functions.pkg.crossplane.io
kubectl get providerconfigs.kubernetes.crossplane.io
kubectl get providerconfigs.helm.crossplane.io
kubectl get providerconfigs.tf.upbound.io

# Composition Functions gerçekten çalışıyor mu — basit bir smoke test
# (gerçek bir XR olmadan da function pod'unun ayakta olduğunu doğrular):
kubectl -n crossplane-system logs deploy/function-kcl --tail=20
```

---

## Neden `provider-terraform` "escape hatch"

ADR-0001 Karar 2.1: Terraform birincil araç değildir; küme *içi* kaynaklar
için tek API Crossplane'dir. `provider-terraform` burada, Crossplane'in
kendi provider'larıyla (kubernetes/helm) ifade **edilemeyen**, nadir görülen
kaynaklar için bir kaçış kapısıdır — örn. bir DNS sağlayıcının Terraform
modülü zaten var ve yeniden yazmak israf olur. **Küme içi tenant kaynakları
için KULLANILMAZ** — bu her zaman `XTenant` composition'ı üzerinden gider.

`ProviderConfig` şu an **hiçbir kimlik bilgisi taşımıyor** (`credentials: []`).
İhtiyaç doğduğunda kimlik bilgisi Vault → ESO → Secret zincirinden gelecek,
asla elle/statik girilmeyecek (bkz. `resources/providerconfigs.yaml`).

---

## Neden `provider-kubernetes` / `provider-helm` `cluster-admin`

Bu iki provider'ın **işlevinin kendisi** kümedeki keyfi kaynakları yönetmektir
(bir `Object`/`Release` CR'ı, hedeflenen HERHANGİ bir Kubernetes kaynağını
temsil edebilir). Crossplane'in varsayılan RBAC toplulaştırması yalnızca
provider'ın **kendi** CRD'lerine erişim verir — bu ikisi için yetersizdir.

`02-control-plane.sh`, kurulumdan sonra bu iki provider'ın (rastgele üretilen
adlı) ServiceAccount'larını etiket seçiciyle bulup `cluster-admin`'e bağlar.
Bu, [provider-kubernetes'in kendi dokümantasyonunun](https://github.com/crossplane-contrib/provider-kubernetes)
önerdiği standart kurulumdur — statik bir *kimlik bilgisi* değil, geniş bir
*yetkidir*; sınırı Kyverno guardrail'leri (L5) çeker.
