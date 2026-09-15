# L1 — Bootstrap

| Dizin / dosya | İçerik |
|---|---|
| `01-underlay.sh` | **Faz 1** — underlay + Keycloak + Harbor kurulum script'i |
| `02-control-plane.sh` | **Faz 2** — ArgoCD + App-of-Apps + Crossplane + Kyverno + ESO |
| `app-of-apps/` | Faz 1'in underlay Application'ları (wave 0-9) + platform AppProject |

`platform/control-plane/apps/` (Faz 2 App-of-Apps child'ları) ve
`platform/control-plane/root-app.yaml.tpl` de bu katmanın parçasıdır ama
L4 dizininde durur — orada hangi bileşenin hangi sync-wave'de olduğu daha
görünür (bkz. [`control-plane/README.md`](../control-plane/README.md)).

---

## `01-underlay.sh` / `02-control-plane.sh` — ortak tasarım kuralları

Kullanım ve doğrulama: [`../underlay/README.md`](../underlay/README.md)

1. **Idempotent** — `helm upgrade --install` + `kubectl apply`. Kaç kez
   çalıştırılırsa çalıştırılsın sonuç aynı; yarıda kesilen kurulum devam eder.
2. **Hardcoded değer yok** — IP, host, parola hepsi `.env`'den; chart sürümleri
   `versions.env`'den. Eksik veya zayıf değerde **başlamadan** durur.
3. **Her adımda readiness** — bir sonraki adıma, öncekinin sağlık kontrolü
   geçmeden geçilmez. Zaman aşımında son durumu yazdırır.
4. **Yıkıcı işlem onayı** — disk silen tek adım (Ceph OSD, Faz 1) açık onay ister.
5. **(Faz 2) Statik kimlik bilgisi yok** — Crossplane provider'ları
   `InjectedIdentity` (in-cluster ServiceAccount) kullanır; hiçbir
   ProviderConfig'te Secret/parola/token yoktur.

---

## Faz 1 → Faz 2 devralma (adoption)

Faz 1'de bileşenler elle kurulur. Faz 2'de ArgoCD gelir ve **aynı kaynakları**
yönetmeye başlar. Bu, dikkat edilmezse çakışma üretir.

### Sorun

`helm install` bir Helm release secret'ı bırakır (`sh.helm.release.v1.*`).
ArgoCD aynı chart'ı kendi Application'ı üzerinden yönetmeye başladığında,
kaynaklarda iki farklı `field manager` olur ve ArgoCD sürekli `OutOfSync`
gösterebilir veya kaynağı yeniden yazabilir.

### Prosedür

```bash
# 1. ArgoCD'yi kur (Faz 2)
#    ArgoCD'nin KENDİSİ app-of-apps ile yönetilmez — yumurta-tavuk.

# 2. AppProject ve root Application'ı render et
#    (PLATFORM_REPO_URL ve PLATFORM_REPO_REVISION .env'e eklenir)
envsubst < app-of-apps/appproject-platform.yaml.tpl | kubectl apply -f -

# 3. ÖNCE ArgoCD'nin mevcut durumu görmesini sağlayın — sync ETMEYİN.
#    root-underlay.yaml'ı syncPolicy.automated KAPALI olarak uygulayın,
#    her Application için `Diff` çıktısını inceleyin:
argocd app diff underlay-cilium

# 4. Diff temizse automated sync'i açın. Değilse önce values'ları
#    Faz 1'de kullanılanla birebir eşitleyin.

# 5. Helm release secret'larını SİLMEYİN.
#    `helm uninstall` YAPMAYIN — kaynakları da siler.
#    ArgoCD ServerSideApply ile sahipliği devralır; eski release secret'ı
#    zararsız şekilde durur ve Faz 2 doğrulandıktan sonra temizlenebilir.
```

### Prune ayarları — bilinçli

| Application | `prune` | Neden |
|---|---|---|
| `underlay-cilium` | `false` | Yanlış prune = cluster ağı gider |
| `underlay-rook-operator` | `false` | CRD prune'u veri kaybı riski |
| `underlay-rook-cluster` | `false` | **CephCluster prune = VERİ KAYBI.** Silme bilinçli olmalı. |
| diğerleri | `true` | Drift temizliği güvenli |

### Sync wave sırası

```
0  Cilium                 ← CNI
1  MetalLB                ← LoadBalancer
2  MetalLB config         ← CRD'ler hazır olduktan sonra
3  Rook operator
4  Rook cluster + havuzlar + ObjectStore
5  StorageClass'lar
6  Keycloak               ← OIDC; Harbor'dan önce
7  Harbor                 ← Rook RGW + Keycloak'a bağımlı
9  Ağ politikaları        ← EN SON
```

Wave 8 boş bırakıldı: Faz 3'te PKI (Vault + cert-manager) buraya girecek.

---

## Katman notu

`app-of-apps/underlay/04-control-plane-base.yaml.tpl` içindeki Harbor ve
Keycloak, ADR-0001'e göre **L4 (control-plane)** bileşenleridir, underlay değil.
Faz 1 görev kapsamında birlikte kuruldukları için root-underlay bunları
wave 6-7 ile çeker. **Faz 4'te kendi root Application'larına taşınacaklar.**

---

## Faz 2: `02-control-plane.sh`

Sıra: **ArgoCD → (AppProject + root-app) → Crossplane/Kyverno/ESO (paralel,
sync-wave 1) → Vault yer tutucu (sync-wave 2, otomatik sync KAPALI)**

### Neden `underlay-root` VE `vault` otomatik sync'siz, ama crossplane/kyverno/eso otomatik

| Application | Otomatik sync | Neden |
|---|---|---|
| `underlay-root` | ❌ Kapalı | Faz 1'de ELLE kurulmuş kaynakları devralıyor — yukarıdaki "Faz 1 → Faz 2 devralma" prosedürü ÖNCE uygulanmalı. Otomatik açılırsa render edilmemiş `${VAR}` şablonları çalışan doğru konfigürasyonun üzerine yazabilir. |
| `crossplane`, `kyverno`, `eso` | ✅ Açık | **Yepyeni kurulumlar** — hiçbir yerde elle kurulmadılar, devralma/çakışma riski yok. |
| `vault` | ❌ Kapalı | Kaynağı şu an yalnızca bir Namespace — Vault chart'ının kendisi Faz 3'te gelecek. |

### `${PLATFORM_REPO_URL}` — repo-genelinde tek seferlik somutlaştırma

**DÜZELTME (Faz 12i, code review #1 — KRİTİK):** bu bölüm ÖNCEDEN "`.tpl`
dosyalarını YERİNDE sed'leyip AYNI `.tpl` uzantısıyla commit edin" diyordu.
Bu YETERSİZDİ: ArgoCD'nin `directory` source'u RESMİ olarak yalnızca
`.yaml`/`.yml`/`.json` uzantılarını yükler (bkz. https://argo-cd.readthedocs.io/
en/stable/user-guide/directory/) — `${VAR}` içindeki değerler çözülse BİLE,
dosya hâlâ `.tpl` ise ArgoCD onu HİÇ GÖRMEZ, root-app SIFIR child
Application keşfeder. Canlı olarak doğrulanmış (kullanıcının kod
incelemesinde): `platform/control-plane/apps/`'daki 16 dosyanın TAMAMI
`.yaml.tpl`'di, hiçbiri ArgoCD'nin standart directory kaynağı tarafından
yüklenmiyordu.

**GÜNCEL PROSEDÜR:** `platform/bootstrap/app-of-apps/underlay/*.tpl`,
`platform/control-plane/apps/*.tpl` ve `platform/policies/security/*.tpl`
(ArgoCD tarafından doğrudan git'ten okunan ÜÇ dizin) KANONİK ŞABLON olarak
KALIR — silinmez/yeniden adlandırılmaz. `platform/bootstrap/
render-app-manifests.sh`, `${VAR}`'ları GERÇEK değerlerle (versions.env +
PLATFORM_REPO_URL/PLATFORM_REPO_REVISION/HARBOR_HOSTNAME) doldurup AYNI
ADDA ama `.tpl` UZANTISI OLMADAN bir KARDEŞ dosya üretir — ArgoCD'nin
GERÇEKTEN okuduğu budur (composition'ların function.k/composition.yaml
İKİLİSİYLE AYNI desen). İKİ dosya da git'e commit edilir:

```bash
export PLATFORM_REPO_URL="https://github.com/<org>/<repo>.git"
export PLATFORM_REPO_REVISION="main"
./platform/bootstrap/render-app-manifests.sh
git add platform/control-plane/apps platform/bootstrap/app-of-apps/underlay platform/policies/security
git commit -m "chore: app manifestlerini render et"
```

`02-control-plane.sh`, root-app'ı uygulamadan ÖNCE bu script'i `--verify`
modunda çağırır (`check_git_placeholders_resolved`) ve DRİFT/eksik `.yaml`
varsa **durur**. `TENANT_REQUESTS_REPO_URL`'e bağımlı 2 dosya
(05/06-tenant-requests-*) BİLİNÇLİ OLARAK render EDİLMEZ (o repo henüz
yok) — script bunları atlayıp uyarır, bu bir HATA sayılmaz; o repo
oluşturulup URL bilinince script yeniden çalıştırılmalı.

### Crossplane provider RBAC'ı neden script'te (manifestte değil)

`provider-kubernetes`/`provider-helm`'in ServiceAccount adı paket
kurulumunda **rastgele** üretilir — statik bir `ClusterRoleBinding`
manifestinde önceden yazılamaz. `02-control-plane.sh`'in `bind_provider_rbac()`
fonksiyonu, kurulumdan SONRA etiket seçiciyle (`pkg.crossplane.io/provider=...`)
SA'yı bulup bağlar. Bu, provider-kubernetes'in kendi dokümantasyonunun
önerdiği standart yoldur (bkz. `control-plane/crossplane/README.md`).
