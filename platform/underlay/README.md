# L2 — Underlay

Bare-metal'de bulut sağlayıcının bedava verdiği primitifleri üreten katman:
ağ, yük dengeleme, depolama.

| Dizin | İçerik | Not |
|---|---|---|
| `cilium/` | CNI, kube-proxy replacement, Hubble, Gateway API, ağ politikaları | Kurulum sırasında **ilk** gelir |
| `metallb/` | L2 mode adres havuzu ve L2Advertisement | IP aralığı `.env`'den |
| `rook-ceph/` | Ceph cluster, RBD pool, CephFS, RGW, bucket'lar | [Sizing](rook-ceph/README.md) |
| `storage-classes/` | `ceph-block` (varsayılan), `ceph-filesystem` | |

**Bağımlılık:** yok (en alt katman).
Bu katmanın üstündeki hiçbir katman, buradaki uygulama detayına bağımlı olmamalıdır —
MetalLB'den BGP'ye geçiş yalnızca bu dizini değiştirmelidir.

---

## Hızlı başlangıç

```bash
cp platform/underlay/.env.example platform/underlay/.env
$EDITOR platform/underlay/.env          # IP havuzu, disk filtresi, parolalar
./platform/bootstrap/01-underlay.sh
```

| Komut | Ne yapar |
|---|---|
| `01-underlay.sh` | Tümünü sırayla kurar |
| `01-underlay.sh --only cilium` | Tek adım (`gateway`/`cilium`/`metallb`/`rook`/`keycloak`/`harbor`/`policies`) |
| `01-underlay.sh --verify-only` | Hiçbir şey kurmaz, yalnızca doğrular |
| `01-underlay.sh --dry-run` | Şablonları render eder, uygulamaz |
| `01-underlay.sh --yes` | Onay sorularını atlar (CI için) |

**Script idempotenttir.** Tekrar tekrar çalıştırılabilir; yarıda kesilen bir
kurulum kaldığı yerden devam eder.

---

## Ön koşullar

| # | Koşul | Kontrol |
|---|---|---|
| 1 | Cluster kubeadm ile **`--skip-phases=addon/kube-proxy`** ile kurulmuş | `kubectl -n kube-system get ds kube-proxy` → NotFound |
| 2 | Node'larda ham (boş) OSD diskleri var | `lsblk -dno NAME,SIZE,TYPE,MOUNTPOINT` |
| 3 | MetalLB IP aralığı ağ ekibinden alınmış, DHCP dışında | PLATFORM_CONTEXT açık karar #1 |
| 4 | Wildcard DNS (`*.apps.<domain>`) delege edilmiş | PLATFORM_CONTEXT açık karar #5 |
| 5 | `kubectl`, `helm`, `envsubst`, `jq`, **bash 4+** kurulu | script kontrol eder |
| 6 | (önerilen) `cilium` CLI kurulu | `cilium status` için |

Script bunların tamamını başlamadan kontrol eder ve eksik varsa **hiçbir şey
uygulamadan** durur.

---

## Kurulum sırası ve gerekçesi

| # | Bileşen | Neden bu sırada |
|---|---|---|
| 1 | Gateway API CRD'leri | Cilium `gatewayAPI.enabled=true` ile açılıyor; CRD yoksa agent hata verir |
| 2 | Cilium | CNI olmadan hiçbir pod Ready olamaz |
| 3 | MetalLB | Harbor/Keycloak `LoadBalancer` Service istiyor |
| 4 | Rook-Ceph | Harbor ve Keycloak PVC + S3 bucket istiyor |
| 5 | Keycloak | Harbor dahil her şey buna OIDC ile bağlanacak (ADR-0001 L4) |
| 6 | Harbor | Rook RGW'yi S3 backend olarak kullanır → Rook hazır olmalı |
| 7 | default-deny | **En son.** Önce her şey sağlıklı olmalı. |

> **Faz 9 eklentisi — kritik sıra notu:** `cilium/values.yaml.tpl`'deki 3
> `serviceMonitor.enabled` bayrağı (hubble, operator, prometheus) bu görevde
> `true`'ya çevrildi. Bu bayraklar `ServiceMonitor` CRD'sini (kube-
> prometheus-stack'in kurduğu) GEREKTİRİR — **CRD yokken Cilium Helm
> kurulumu "no matches for kind ServiceMonitor" hatasıyla BAŞARISIZ olur.**
> Doğru sıra: `platform/control-plane/observability/` (kube-prometheus-stack)
> ÖNCE kurulmalı, sonra `01-underlay.sh --only cilium` YENİDEN çalıştırılıp
> (idempotent `helm upgrade`) Hubble/operator ServiceMonitor'ları oluşur.
> İlk kurulumda (Faz 1, observability henüz yokken) bu script çalıştırılırsa
> ve observability henüz kurulu değilse Cilium adımı BAŞARISIZ olur —
> bu KASITLIDIR (sessizce yarı-doğru bir konfigürasyonla devam etmek yerine
> net bir hata vermek tercih edildi).

---

## Doğrulama adımları (bileşen başına)

Script her adımdan sonra bunları otomatik çalıştırır; elle de yapabilirsiniz.

| Bileşen | Doğrulama komutu | Beklenen |
|---|---|---|
| Gateway API | `kubectl get crd \| grep gateway.networking` | 4+ CRD |
| Cilium | `cilium status --wait` | Tüm satırlar OK, `KubeProxyReplacement: True` |
| Cilium | `kubectl get gatewayclass` | `cilium` → `Accepted=True` |
| Hubble | `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` | UI açılıyor, akış görünüyor |
| MetalLB | `kubectl -n metallb-system get ipaddresspool` | Havuz listeleniyor |
| MetalLB | **smoke test:** geçici LoadBalancer Service | `EXTERNAL-IP` havuzdan atanıyor |
| Rook-Ceph | `kubectl get storageclass` | `ceph-block` (default), `ceph-filesystem`, `ceph-bucket` |
| Rook-Ceph | `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status` | `HEALTH_OK`, `6 osds: 6 up, 6 in` |
| Rook-Ceph | **smoke test:** RWO + RWX PVC | İkisi de `Bound` |
| Rook-Ceph | `kubectl -n rook-ceph get obc` | `backup-bucket`, `harbor-registry` → `Bound` |
| Keycloak | `curl -sf http://<kc>/realms/platform/.well-known/openid-configuration` | `issuer` alanı dolu JSON |
| Harbor | `curl -sf http://<harbor>/api/v2.0/health` | Tüm bileşenler `healthy` |
| Harbor | `curl -u admin:*** http://<harbor>/api/v2.0/scanners` | Trivy listelenmiş, `is_default: true` |
| Politikalar | `kubectl get ciliumclusterwidenetworkpolicy` | 2 veya 3 politika |
| Politikalar | **smoke test:** DNS çözümlemesi | default-deny sonrası hâlâ çalışıyor |

Hepsini tekrar çalıştırmak için: `./platform/bootstrap/01-underlay.sh --verify-only`

---

## Sırlar ve parametreler

| Nerede | Ne | Git'te mi |
|---|---|---|
| `.env` | IP aralığı, host adları, disk filtresi, parolalar | ❌ `.gitignore`'da |
| `.env.example` | Aynı anahtarlar, **boş değerlerle** | ✅ |
| `versions.env` | Chart sürüm sabitlemeleri | ✅ |
| `*.yaml.tpl` | `${VAR}` yer tutuculu şablonlar | ✅ |
| `*/rendered/`, `*.rendered.yaml` | Render edilmiş çıktı | ❌ `.gitignore`'da |
| Kubernetes Secret'ları | Script tarafından `.env`'den üretilir | ❌ Hiç Git'e girmez |
| Ceph S3 anahtarları | **Rook üretir**, script OBC secret'ından okur | ❌ Hiç insan görmez |

Script, zorunlu değişken boşsa veya parola 14 karakterden kısaysa
**başlamadan durur**. Bilinen varsayılanlar (`Harbor12345` vb.) reddedilir.

---

## Bilinen riskler ve teknik borç

| # | Konu | Etki | Planlanan çözüm |
|---|---|---|---|
| 1 | **Bitnami imaj dağıtım politikası değişti.** Keycloak chart'ı Bitnami imajlarını çeker; `bitnami/*` etiketlerinin bir kısmı `bitnamilegacy`'ye taşındı veya abonelik gerektiriyor. | Keycloak kurulumu `ImagePullBackOff` verebilir | **Kurulum öncesi doğrulayın.** İç mirror varsa `.env` → `KEYCLOAK_IMAGE_REGISTRY`. Kalıcı çözüm: Faz 4'te resmî Keycloak Operator'a geçiş. |
| 2 | Harbor chart'ının S3 `existingSecret` anahtar isimleri sürüme göre değişir | Harbor registry S3'e bağlanamaz | Kurulum öncesi: `helm show values harbor/harbor --version <v> \| grep -A25 imageChartStorage` |
| 3 | Harbor ve Keycloak kendi bundled PostgreSQL'lerini kullanıyor | HA yok, yedek yok | Faz 4: CloudNativePG'ye taşınacak |
| 4 | TLS henüz yok (Harbor, Keycloak, RGW, Ceph dashboard hepsi HTTP) | Küme içi düz metin | Faz 3: Vault PKI + cert-manager (ADR-0001 Karar 2.3) |
| 5 | Keycloak `production: false` | Üretime uygun değil | Faz 3: TLS gelince `true` |
| 6 | default-deny muafiyet listesi tüm platform namespace'lerini kapsıyor | Platform bileşenleri arası trafik kısıtsız | Faz 4-5: bileşen başına açık politika, liste daraltılır |
| 7 | Sürümler yazıldığı andaki kararlı sürümler | Eskimiş olabilir | İlk kurulumdan önce `versions.env`'i doğrulayın |

---

## Faz 1 → Faz 2 devralma (ArgoCD)

Faz 1'de bileşenler `helm upgrade --install` ile **elle** kurulur; ArgoCD
henüz yoktur. `platform/bootstrap/app-of-apps/` altındaki Application
manifestleri şimdiden yazılmıştır ki Faz 2'de ArgoCD bunları **devralabilsin**.

Devralma gerçek bir sürtünme noktasıdır ve adımları
[`platform/bootstrap/README.md`](../bootstrap/README.md) içinde belgelenmiştir.
