# Vault — HA / Raft, PKI, Kubernetes Auth

ADR-0001 Karar 2.3. Kurulum: [`platform/bootstrap/03-pki.sh`](../../bootstrap/03-pki.sh).
Init/unseal: [`docs/runbooks/vault-unseal.md`](../../docs/runbooks/vault-unseal.md).

---

## Root CA izolasyonu — dürüst bir not

Görev, Root CA'nın **ayrı bir "root" Vault namespace'inde** tutulmasını
istiyor. **Vault Namespaces, HashiCorp Vault ENTERPRISE'ın lisanslı bir
özelliğidir** — bu platform açık kaynak (OSS) Vault kullanıyor (ADR-0001'de
Enterprise lisansı hiç gündeme gelmedi ve maliyeti kabul edilmedi). Bu
yüzden **gerçek Vault Namespace kullanılmıyor.**

Bunun yerine, OSS içinde ulaşılabilen en yakın karşılığı uyguladık:

| Enterprise'da olsaydı | OSS'de yaptığımız |
|---|---|
| Ayrı `root` namespace, ayrı RBAC sınırı | Ayrı bir **mount path** (`pki-root`, diğerlerinden (`pki-int-*`) tamamen ayrı) |
| Namespace bazlı erişim izolasyonu | **Ayrı bir Vault policy** (`root-ca-admin-policy.hcl`) — hiçbir günlük operasyon rolüne (cert-manager, crossplane) atanmaz |
| Kalıcı olarak erişilemez root | **Break-glass prosedürü** (docs/runbooks/vault-unseal.md §6) — `root-ca-admin` policy'si normal zamanda KİMSEYE bağlı değil |

**Gerçek offline root** (Vault'un kendisinin bile hiç bilmediği bir kök)
istenirse, tek yol Root CA'yı **tamamen ayrı, fiziksel/mantıksal olarak
izole bir Vault instance'ında** (veya tamamen offline bir OpenSSL kök CA'da)
tutup yalnızca ara sıra devreye alıp Intermediate CSR'larını imzalatmaktır.
Bu, mevcut 3-node bare-metal kapsamının önemli ölçüde ötesinde bir operasyonel
yük getirir (ayrı bir cluster/host, ayrı bir unseal prosedürü, ayrı bir
network yolu) — **bu fazda bilinçli olarak yapılmadı.** İleride gerekirse
`pki-root` mount'u buraya taşınabilir; hiçbir tüketici (cert-manager,
compositions) bunun farkına varmaz çünkü onlar yalnızca `pki-int-*`
mount'larını bilir.

---

## Neden Raft (integrated storage), Consul/etcd değil

- **Ek bir bağımlılık yok.** Consul veya harici bir depolama backend'i,
  işletilecek BAŞKA bir dağıtık sistem demektir. Raft, Vault'un KENDİ
  process'i içinde çalışır.
- **Rook-Ceph zaten var.** Raft'ın PV ihtiyacı (`ceph-block`, `ReadWriteOnce`)
  Faz 1'in ürettiği StorageClass ile karşılanıyor — yeni bir depolama
  sistemi gerekmiyor.
- 3 node → 3 Raft peer → quorum: 2/3. Bir node kaybında Vault **yazılabilir**
  kalır (Rook-Ceph'in 3/2 replikasyon ilkesiyle birebir aynı mantık).

---

## Vault'un kendi TLS'i — bilinçli kabul edilen sınır

Vault'un dinleyicisi (`listener "tcp"`) bu fazda **`tls_disable = 1`**.
Gerekçe: Vault'un kendi sunucu sertifikasını **kendi PKI'sinden**
imzalatması (self-referential bootstrap) klasik bir tavuk-yumurta
problemidir — Vault henüz PKI mount'una sahip değilken/unseal değilken
bu sertifikayı nasıl üretecek? Bunu bu fazda kör bir otomasyonla çözmeye
çalışmak, **Vault'un erişilemez hale gelmesi riski** taşır — bu, mevcut
riski (küme-içi düz metin, Cilium NetworkPolicy ile korunuyor) kabul
etmekten çok daha tehlikelidir.

**Teknik borç olarak kaydedildi** (PLATFORM_CONTEXT.md). Gelecekteki
kapatma yolu: Vault unsealed VE `pki-int-*` hazır olduktan SONRA, Vault'un
kendi sertifikasını `pki-int-<env>` üzerinden imzalatıp listener config'ini
`tls_disable = 0` + sertifika yoluna güncelleyip **kontrollü, tek node'da
test edilerek** yeniden başlatmak. Bu ayrı bir runbook gerektirir.

---

## Doğrulama

```bash
kubectl -n vault get pods                    # 3/3 Running
kubectl -n vault exec vault-0 -- vault status   # Sealed: false
kubectl get secretengines 2>/dev/null || true
./platform/bootstrap/03-pki.sh --verify-only
```
