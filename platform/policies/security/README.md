# L5 — Güvenlik sertleştirme politikaları (Faz 10)

`../validation/` ile AYNI katmanda (L5 guardrails) ama ayrı bir dizinde
tutulur çünkü bu politikalar tenant self-servis akışının değil, **platform
genelindeki tedarik zinciri/uyum** duruşunun bir parçasıdır.

| Dosya | Ne yapar | Mod |
|---|---|---|
| `01-require-signed-images.yaml.tpl` | Harbor'dan çekilen imzasız (Cosign) imajları reddeder | **Enforce** |
| `02-require-pss-restricted-clusterwide.yaml` | Platform sistemi namespace'leri HARİÇ her namespace'te PSS restricted zorunlu | **Enforce** |
| `pod-security-admission-configuration.yaml` | kube-apiserver'ın kendi PSS varsayılanı (kubeadm seviyesi, kubectl apply İLE UYGULANMAZ) | — |

---

## 1. İmza doğrulama (`require-signed-images`)

**Neden Cosign, Notation değil:** platformun mevcut zinciri (syft/Trivy/
Harbor) zaten Cosign ekosistemiyle uyumlu; Notation ayrı bir trust-policy +
plugin gerektirir. Bilinçli bir kapsam daraltması — teknik borç olarak
kaydedildi (bkz. PLATFORM_CONTEXT.md).

**GERÇEK uçtan uca doğrulama** (bu görevde yapıldı — `kyverno test` bunu
statik olarak test EDEMEZ çünkü `verifyImages` gerçek bir registry'ye ağ
çağrısı yapar):
- Yerel bir Docker registry + gerçek `cosign generate-key-pair` + bir imaj
  imzalı, biri imzasız bırakıldı.
- `kyverno apply --registry` ile: imzalı imaj **kabul edildi**, imzasız
  imaj **reddedildi** ("no signatures found").
- **Kritik bulgu:** Homebrew'in verdiği cosign v3.1.3 ile imzalanan
  imajlar bile Kyverno 1.19.1 tarafından reddedildi (cosign v3, imzayı OCI
  1.1 Referrers API + yeni sigstore-bundle formatında yazıyor; Kyverno
  1.19.1'in gömülü doğrulayıcısı bunu ANLAMIYOR). GitHub'dan doğrudan
  indirilen **cosign v2.4.1** ile imzalanan aynı imaj Kyverno tarafından
  KABUL EDİLDİ. Ayrıntı ve tekrar-üretme adımları:
  [`../tests/require-signed-images/README.md`](../tests/require-signed-images/README.md).
- **Aksiyon:** CI'daki imza atma adımı `cosign`'ı **v2.4.1'e sabitler**
  (bkz. `image-supply-chain.yaml`) — `latest` KESİNLİKLE kullanılmaz.

**Kurulum notu:** `01-require-signed-images.yaml.tpl`'daki
`harbor.apps.platform.internal/*` yer tutucusu, gerçek `HARBOR_HOSTNAME`
ile (envsubst veya elle) değiştirilmeden bu politika HİÇBİR imaja
uygulanmaz (`imageReferences` eşleşmez) — bu KASITLI bir fail-safe DEĞİL,
gerçek kurulum ADIMIDIR, unutulmamalıdır.

---

## 2. Cluster-genelinde PSS "restricted" + istisna süreci

08 (`../validation/08-require-pss-restricted.yaml`) yalnızca `tenant-*`
namespace'lerini kapsıyordu (Faz 6b). Bu görev, kapsamı **platform sistemi
namespace'leri hariç HER namespace'e** genişletti — iki bağımsız katmanla
(bkz. `02-require-pss-restricted-clusterwide.yaml`'ın başlık yorumu):
kube-apiserver'ın kendi `PodSecurityConfiguration`'ı + Kyverno ClusterPolicy.

**GERÇEK doğrulama:** `kyverno test platform/policies/tests/
require-pss-restricted-clusterwide/` — 3 senaryo (etiketsiz namespace →
red, etiketli → kabul, istisna listesindeki `rook-ceph` → muaf) YEŞİL.
Tüm politika paketi (36 test, 33 eski + 3 yeni) birlikte YEŞİL.

### PSS istisna süreci

Bir namespace, restricted profiliyle GERÇEKTEN çalışamayan bir iş yükü
barındırıyorsa (örn. bir host-level ajan, bir CSI driver) iki yoldan biri
izlenir:

**A) Platform bileşeni ise (kalıcı, platform ekibi tarafından işletilen):**
`02-require-pss-restricted-clusterwide.yaml`'ın `exclude.any[].resources.names`
listesine eklenir **VE** `pod-security-admission-configuration.yaml`'ın
`exemptions.namespaces` listesine **AYNI ANDA** eklenir (biri unutulursa
iki katman birbirinden sapar). Bu bir Git PR'ıdır — review, bu değişikliği
platformun geri kalanına AÇIKÇA gösterir.

**B) Tenant/uygulama namespace'i ise (geçici, gerekçeli, süreli):** kalıcı
bir istisna listesi yerine bir Kyverno `PolicyException` CR'ı açılır:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: pss-exception-<namespace>-<tarih>
  namespace: kyverno
  annotations:
    platform.internal/pss-exception-justification: >-
      <NEDEN restricted ile çalışamıyor — somut hata/loglar>
    platform.internal/pss-exception-approved-by: "<platform ekibi üyesi>"
    platform.internal/pss-exception-review-date: "2026-12-01"
spec:
  exceptions:
    - policyName: require-pss-restricted-clusterwide
      ruleNames:
        - require-restricted-labels
  match:
    any:
      - resources:
          kinds: [Namespace]
          names: ["<namespace-adı>"]
```

`02-require-pss-restricted-clusterwide.yaml`'ın `exceptions-require-
justification` kuralı, bu iki annotation'dan biri BOŞSA istisnanın
KENDİSİNİ reddeder — gerekçesiz/onaysız bir istisna açılamaz.

**Süreç:** (1) istisna talebi bir PR ile açılır (annotation'lar zorunlu
alanlardır), (2) platform ekibi review eder ve `approved-by` alanını
doldurur, (3) `review-date`'te istisna gözden geçirilip ya kaldırılır ya
da (hâlâ gerekliyse) tarihi güncellenir. **Otomatik süre dolumu YOK** —
bu elle takip edilen bir süreçtir (teknik borç: bir CronJob/script
`review-date`'i geçmiş PolicyException'ları raporlayabilir, bu görev
kapsamında YAZILMADI).

---

## Testleri çalıştırmak

```bash
kyverno test platform/policies/tests/               # tüm paket, 36 test
kyverno test platform/policies/tests/require-pss-restricted-clusterwide/
```

İmza doğrulama politikası `kyverno test` ile test EDİLEMEZ (gerçek
registry gerektirir) — bkz. `tests/require-signed-images/README.md`.
