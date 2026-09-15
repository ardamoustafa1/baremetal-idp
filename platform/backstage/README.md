# Backstage self-servis portalı

Uygulama artık bu repodadır: `portal/` Backstage 1.54.0 kaynaklarını ve Yarn lockfile'ını, `Dockerfile` build'i, `app/` Helm/SSO konfigürasyonunu taşır. GitHub Actions tercih edilmiştir.

## Akış

Form → gerçek `fetch:template` action → `publish:github:pull-request` → tenant-requests CI → main'e merge → git-files ApplicationSet → Crossplane → Ready Claim → katalog.

- Yeni dosyalar: `clusters/platform/tenants/<team>-<environment>.yaml` ve `clusters/platform/postgresql/<name>.yaml`. Eski `tenants/*.yaml` / `postgresql/*.yaml` yolları da desteklenir.
- `platform` yolu ArgoCD `in-cluster` hedefine gider. Diğer cluster adları ArgoCD'ye kaydedilmeli, tenant AppProject destinations'a, form enum'una ve CI `ALLOWED_CLUSTERS` listesine eklenmelidir. Her hedefte Crossplane/XRD/composition ve `tenant-requests` namespace'i önceden kurulmalıdır. Mevcut portal okuyucusu bulunduğu platform cluster'ını gösterir; uzak cluster gözlemi ayrıca okuyucu/kimlik yapılandırması gerektirir.
- Git generator ve Application kaynakları aynı `main` branch'ini izler; 60 saniye polling. ArgoCD ApplicationSet webhook endpoint'iyle hızlandırılabilir.
- Ayrı `tenant-requests` AppProject yalnızca iki Claim türünü kabul eder. Repo silme/claim silme PR'ları prune nedeniyle gerçek kaynağı silebilir; CODEOWNERS/branch protection uygulayın.

## Kurulum

1. P1–P7 altyapısını gerçekten kurun. Gerçek cluster bağlantısı bu çalışma alanında yoktur.
2. Secret olmayan değerleri kendi shell'inizde belirleyin:

```bash
export PLATFORM_REPO_URL=https://github.com/ORG/platform.git
export PLATFORM_BASE_DOMAIN=example.internal
export KEYCLOAK_HOSTNAME=keycloak.example.internal
export TENANT_REQUESTS_REPO_URL=https://github.com/ORG/tenant-requests.git
export BACKSTAGE_IMAGE_REGISTRY=harbor.example.internal
export BACKSTAGE_IMAGE_TAG=COMMIT_SHA
export BACKSTAGE_USER_EMAIL=approved-user@example.internal
python3 platform/backstage/configure.py
```

Bu komut GitOps ConfigMap'lerini, image referansını, **sabit hedef repolu** iki formu ve giriş yapabilecek catalog User kaydını üretir; ArgoCD'nin okuyabileceği 05/06/07 `.yaml` manifestlerini ise KENDİ mantığıyla DEĞİL, `platform/bootstrap/render-app-manifests.sh --require-tenant-requests`'i (tek doğruluk kaynağı — SUBST_VARS whitelist'i + çözülmemiş değişken güvenlik ağı + drift kontrolü İÇERİR) çağırarak üretir (code review #11'in yan bulgusu — bu script ÖNCEDEN KENDİ, bağımsız bir `.tpl`→`.yaml` render mantığı taşıyordu, bu iki render yolunun birbirinden SESSİZCE SAPMASI riski TAŞIYORDU). Bu yüzden `configure.py`'yi çalıştırmak için `PLATFORM_REPO_URL`/`TENANT_REQUESTS_REPO_URL` DIŞINDA ayrıca `render-app-manifests.sh --verify` çalıştırmaya GEREK YOKTUR — TEK komut ikisini de kapsar. Yeni kullanıcıları `catalog/users.yaml` içinde ayrı YAML dokümanları olarak tanımlayın. Formlar `configure.py` öncesinde test için RepoUrlPicker içerir; üretimde hedef repo formdan değiştirilemez. GitHub token'ını yalnızca bu repoya Contents/Pull requests read-write yetkisiyle sınırlandırın.

**NOT (code review #13):** `07-backstage.yaml.tpl`'in ArgoCD Application'ı KASITLI OLARAK `syncPolicy.automated` YOK (Velero/Loki/Tempo İLE AYNI "adoption-only" deseni) — `app/values.yaml`'ın git'teki VARSAYILAN hâli `image.registry`/`image.tag: REPLACE_ME` içerir (yalnızca BU script GERÇEK değerle değiştirir); otomatik sync açık olsaydı, `configure.py` çalıştırılıp commit edilmeden ÖNCE ArgoCD REPLACE_ME imajını çekmeye çalışırdı VE `selfHeal` herhangi bir manuel düzeltmeyi geri alırdı. `configure.py`'yi çalıştırıp değişiklikleri commit ETTİKTEN SONRA, isterseniz bu Application'a elle `argocd app sync backstage` ile senkronlayın veya automated'ı kalıcı olarak açın.

3. Vault'ta `platform/backstage/{oidc,github,database,session}` yollarını doldurun. Property adları `app/resources/secretstore-externalsecret.yaml` içinde tanımlıdır. Session secret güçlü, kalıcı rastgele bir değer olmalıdır. `03-pki.sh --only auth` ESO platform rolünü kurar; `04-backstage.sh --only oidc` mevcut Keycloak client secret'ını Vault'a alır. Kimlik bilgilerini Git'e yazmayın.
4. `docker build -f platform/backstage/Dockerfile -t "$BACKSTAGE_IMAGE_REGISTRY/platform/backstage:$BACKSTAGE_IMAGE_TAG" platform/backstage` ile image üretin ve kendi registry'nize push edin.
5. Platform `.tpl` dosyalarındaki repo/revizyon yer tutucularını önceki fazların prosedürüyle somutlaştırıp commit edin. ArgoCD `05-tenant-requests-project`, `06-tenant-requests-appset`, `07-backstage` manifestlerini App-of-Apps üzerinden alır. Helm chart sürümü **2.6.1**.
6. `app/resources/httproute.yaml.example` dosyasını mevcut TLS Gateway'inizin adı/listener'ı ve gerçek host ile `.yaml` olarak oluşturun. DNS ve Keycloak TLS'i P1/P3 bağımlılıklarıdır. `04-backstage.sh` rollout ve ESO Ready durumunu doğrular.

## Keycloak SSO

P1'in **platform** realm'i ve confidential `backstage` client'ı kullanılır. Callback tam olarak `https://backstage.<domain>/api/auth/oidc/handler/frame` olmalıdır. Eski realm'e yeniden import mevcut client'ı güncellemez: `04-backstage.sh --only oidc` client'ı Admin API üzerinden idempotent oluşturur/günceller, secret'ı Vault'a eşitler ve eksik session secret'ını üretir.

Backend OIDC modülü, gerçek Keycloak giriş ekranı ve `emailMatchingUserEntityProfileEmail` resolver bağlıdır. Katalogda aynı email'e sahip User yoksa giriş reddedilir; guest fallback yoktur. Keycloak'ta email'leri doğrulanmış ve operatör kontrollü tutun. Grup üyeliği catalog User/Group kayıtlarıyla yönetilir, GitHub kullanıcı adı OIDC grup kimliği sayılmaz.

[Resmî OIDC yapılandırması](https://backstage.io/docs/auth/oidc/).

## Kubernetes ve Crossplane

Resmî Kubernetes plugin'i namespace/pod/workload görünürlüğünü sağlar. `platform-crossplane` yerel backend plugin'i Claim'i ve `spec.resourceRef` ile bağlı Composite'i okur; `Crossplane` sekmesi Ready/Synced/reason/message durumunu 15 saniyede yeniler. Secret içerikleri/exec yetkisi verilmez. Projected ServiceAccount token'ı her API isteğinde yeniden okunur. Portalın giriş yapabilen kullanıcıları bu salt okunur platform görünümünü paylaşır; tenant başına görünürlük izolasyonu uygulanmış değildir.

## Otomatik catalog-info

Composition'larda mevcut ConfigMap `data['catalog-info.yaml']` çıktısı kullanılır. `portal/packages/backend/src/platformCatalog.ts` gerçek bir EntityProvider'dır; konfigürasyonda varsayılan olarak var olmayan bir Kubernetes provider'ına güvenmez.

60 saniyede Claim'ler ve etiketli ConfigMap'ler okunur; yalnızca **Ready=True** olan Claim'in ConfigMap'i katalogda yayınlanır. Değişen içerik güncellenir, silinen/hazır olmayan Claim katalogdan kaldırılır. Bir Kubernetes okuması başarısızsa önceki snapshot korunur. Kubernetes ve Crossplane ilişki anotasyonları provider tarafından eklenir. Git deposuna bot commit'i veya Backstage public REST API'sine entity push gerekmez. Kaynak sahibi başlangıçta `platform-team` olur; ayrı tenant erişim kontrolü değildir.

## CI ve doğrulama

`tenant-requests/.github/workflows/validate.yaml` her PR'da tüm mevcut Claim'leri kontrol eder (yalnızca değişen dosyaları seçip bozuk Claim kaçırmaz): XRD JSON Schema + kubeconform; Claim→XR dönüşümü + gerçek Docker `crossplane render`; render çıktısına Kyverno 07/08; mevcut `kyverno test` regresyon paketi. CEL'in iki çapraz alan kuralı ayrıca kontrol edilir; `crossplane render` kendi başına bir XRD şema doğrulayıcı değildir.

Repository variables: `PLATFORM_REPO=ORG/platform`, `PLATFORM_REPO_REF=<korunan branch veya commit SHA>`. Private platform repo için read-only `PLATFORM_REPO_TOKEN` gereklidir. Fork PR'larına secrets verilmez; private kaynak erişimi yoksa kontrol başarısız olur, inceleme sonrası kurum içi branch üzerinden çalıştırılır.

`comment.yaml` ayrı `workflow_run` ile sonuç/commit/rapor bağlantısını PR yorumuna yazar. PR kodunu write token ile çalıştırmaz ve log metnini JavaScript kaynak koduna interpolate etmez. Eski commit'e ait sonuç güncel PR yorumunu ezmez. Bu workflow default branch'te bulunmalıdır. Branch protection'da `validate` job'unu zorunlu yapın.

Yerel komutlar:

```bash
python3 tenant-requests/.github/scripts/test-validation.py
# portal dizininde:
node .yarn/releases/yarn-4.13.0.cjs install --immutable
node .yarn/releases/yarn-4.13.0.cjs tsc --noEmit
node tests/scaffolder.cjs
node .yarn/releases/yarn-4.13.0.cjs workspace backend test --watch=false --runInBand platformCatalog.test.ts
node .yarn/releases/yarn-4.13.0.cjs build:backend
```

Scaffolder testi **gerçek iki Backstage action'ını** çalıştırır; GitHub client'ını test double ile değiştirip API'ye gönderilecek dosya yolunu, base64 içeriğini ve PR çıktısını doğrular. Üretilen iki Claim gerçek schema/render/policy kontrollerinden geçirilir. Gerçek GitHub PR'ı oluşturulduğu veya canlı Keycloak SSO yapıldığı anlamına gelmez.

Canlı kabul: Keycloak ile oturum açın; iki formdan PR oluşturun; Actions check + PR yorumunu görün; geçersiz tier/HA-small değişikliğinin kırmızı olduğunu görün; geçerli PR'ı merge edin; Argo Application Synced, Claim Ready ve katalog/Kubernetes/Crossplane sekmelerini doğrulayın.

## Canlıya geçmeden önce ZORUNLU — çok kullanıcılı yetkilendirme testi (code review #12)

**Bu bölüm KASITLI OLARAK bir kontrol listesidir, bir uygulama DEĞİLDİR** —
gerçek Keycloak kullanıcıları + gerçek bir Backstage dağıtımı GEREKTİRİR,
bu görevin sandbox'ında YAPILAMAZ. Backend hâlâ `@backstage/plugin-
permission-backend-module-allow-all-policy` kullanıyor (bkz.
`portal/packages/backend/src/index.ts`, `PLATFORM_CONTEXT.md` teknik borç
#40) — yani BU KONTROL LİSTESİ ŞU AN ÇALIŞTIRILSA, "tenant sahibi" ile
"başka tenant kullanıcısı" arasında HİÇBİR FARK GÖZLEMLENMEZ (ikisi de
HER ŞEYİ yapabilir) — asıl amacı, gerçek bir sahiplik-bazlı
`PermissionPolicy` (#40) VE Keycloak→catalog grup senkronizasyonu (#41)
YAZILDIKTAN SONRA bu ikisinin GERÇEKTEN çalıştığını KANITLAMAKTIR. Bu
kontrol listesi olmadan #40/#41 "tamamlandı" sayılmamalıdır — yazılı bir
permission policy'nin KENDİSİ, doğru davrandığının KANITI DEĞİLDİR.

Dört ayrı kullanıcı kimliğiyle (gerçek Keycloak hesapları) TEKRARLANMALI:
**(a)** bir tenant'ın SAHİP grubundaki kullanıcı, **(b)** BAŞKA bir
tenant'ın kullanıcısı, **(c)** `platform-admins` grubundaki bir kullanıcı,
**(d)** Keycloak'ta grup üyeliği SONRADAN KALDIRILAN bir kullanıcı (aynı
oturum/token hâlâ AKTİFKEN VE token YENİLENDİKTEN SONRA — ikisi AYRI
senaryolardır). Her kimlik için AŞAĞIDAKİ altı akış test edilmeli:

1. **Giriş** — OIDC login başarılı, doğru kullanıcı/grup bilgisiyle profil oluşur.
2. **Katalog görüntüleme** — kullanıcı YALNIZCA kendi eriştiği kaynakları mı
   görüyor, yoksa TÜM tenant'ların catalog entity'lerini mi (#40 kapanmadan
   İKİNCİSİ BEKLENİR — bu BİLİNEN, KABUL EDİLMİŞ bir açıktır, HATA RAPORU
   DEĞİL).
3. **Şablon çalıştırma** (scaffolder) — (b) BAŞKA tenant kullanıcısı
   KENDİ tenant'ı ADINA bir template TETİKLEYEBİLİYOR MU? (#40 kapanmadan
   EVET BEKLENİR — kapandıktan SONRA HAYIR olmalı.)
4. **PR oluşturma** — template'in ürettiği PR'ın hedef repo/branch'i
   doğru mu, `tenant-requests` reposunun CODEOWNERS/branch-protection'ı
   (bu repo kapsamı DIŞI, GitHub ayarı) GERÇEKTEN devrede mi?
5. **Kubernetes kaynaklarını görüntüleme** — kullanıcı YALNIZCA kendi
   tenant namespace'inin kaynaklarını mı görüyor (Backstage'in Kubernetes
   plugin'i RBAC-farkında mı, yoksa portal'ın KENDİ ServiceAccount'ının
   geniş görünürlüğü mü sunuluyor — bu da AYRI, kontrol edilmesi gereken
   bir soru).
6. **Yetki kaldırıldıktan SONRA erişimin KESİLMESİ** — (d) kullanıcısının
   Keycloak grubu kaldırıldıktan SONRA: (i) MEVCUT oturum/token hâlâ
   erişebiliyor mu (JWT süresi dolana kadar BEKLENEN bir gecikme mi,
   yoksa GÜVENLİK AÇIĞI mı — bu, token TTL'sine göre değerlendirilmeli),
   (ii) token YENİLENDİKTEN/yeniden login OLUNDUKTAN sonra erişim
   GERÇEKTEN kesiliyor mu.

Bu altı akışın TAMAMI dört kimlik İÇİN geçmeden (yalnızca #40/#41
"yazıldı" olması YETERLİ DEĞİL) portal ÜRETİME hazır SAYILMAMALIDIR.
