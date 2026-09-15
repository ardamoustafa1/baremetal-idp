# Platform — Bare-metal Internal Developer Platform

Bare-metal, çok-kiracılı (multi-tenant), self-servis bir **Internal Developer
Platform**. Ürün ekipleri kendi altyapılarını (namespace, kota, ağ politikası,
veritabanı, registry projesi, secret, sertifika, yedek) **bir PR açarak**
talep eder; platform ekibi ticket işlemez, API sağlar.

> **Mevcut durum:** Faz 0 — yalnızca dokümantasyon ve repo iskeleti.
> **Henüz hiçbir cluster işlemi yapılmadı.**
> Güncel durum için → [`platform/docs/PLATFORM_CONTEXT.md`](platform/docs/PLATFORM_CONTEXT.md)

---

## Mimari özeti

7 katman; her katman yalnızca kendi altındakine bağımlıdır.

| # | Katman | Dizin | Bileşenler |
|---|---|---|---|
| L7 | Developer Portal | [`platform/backstage/`](platform/backstage/) | Backstage |
| L6 | Tenant API | [`platform/compositions/`](platform/compositions/) | Crossplane v2 XRD + KCL composition functions |
| L5 | Guardrails | [`platform/policies/`](platform/policies/) | Kyverno |
| L4 | Platform servisleri | [`platform/control-plane/`](platform/control-plane/) | Harbor, Keycloak, CloudNativePG, ESO, kube-prometheus-stack, OpenCost, Velero |
| L3 | Kimlik & PKI | [`platform/pki/`](platform/pki/) | Vault, cert-manager |
| L2 | Underlay | [`platform/underlay/`](platform/underlay/) | Cilium, MetalLB, Rook-Ceph |
| L1 | Bootstrap | [`platform/bootstrap/`](platform/bootstrap/) | ArgoCD (app-of-apps) |

Katman seçimlerinin gerekçeleri → [ADR-0001](platform/docs/adr/0001-architecture.md)

---

## Repo yapısı

```
.
├── README.md
├── platform/
│   ├── bootstrap/          # L1 — ArgoCD kurulumu ve app-of-apps kökü
│   ├── underlay/           # L2 — CNI, load balancer, depolama
│   ├── pki/                # L3 — Vault, cert-manager, güven paketleri
│   ├── control-plane/      # L4 — platform servisleri
│   ├── policies/           # L5 — Kyverno validate/mutate/generate
│   ├── compositions/       # L6 — XRD + KCL composition functions
│   ├── backstage/          # L7 — portal, scaffolder template'leri, katalog
│   ├── examples/           # örnek tenant talepleri (small/medium/large)
│   └── docs/
│       ├── PLATFORM_CONTEXT.md   # "şu an neredeyiz" — canlı takip dosyası
│       ├── conventions.md        # isimlendirme & etiketleme kuralları
│       └── adr/                  # mimari karar kayıtları
└── tenant-requests/        # AYRI REPO İSKELETİ — tenant talepleri buraya PR açar
```

> `tenant-requests/` burada iskelet olarak durur; canlıya alınırken **ayrı bir
> Git reposuna** taşınacaktır. Gerekçe → [ADR-0001, Bölüm 3](platform/docs/adr/0001-architecture.md)

---

## Bootstrap

Aşağıdaki sıra **normatiftir** — katmanlar arası tek yönlü bağımlılıktan gelir.
Adımların içerikleri ilgili faz tamamlandıkça doldurulur.

| Adım | Ne yapılır | Durum |
|---|---|---|
| 0 | Ön koşullar: node'lar, kube-proxy'siz kubeadm, ham diskler, DNS, MetalLB IP havuzu | 📋 [underlay/README.md](platform/underlay/README.md#ön-koşullar) |
| 1 | Underlay + Keycloak + Harbor: `./platform/bootstrap/01-underlay.sh` | ✅ script hazır, çalıştırılmayı bekliyor |
| 2 | ArgoCD + App-of-Apps + Crossplane + Kyverno + ESO: `./platform/bootstrap/02-control-plane.sh` | ✅ script hazır, çalıştırılmayı bekliyor |
| 3 | PKI: `./platform/bootstrap/03-pki.sh` — Vault (HA/Raft) → [init/unseal](platform/docs/runbooks/vault-unseal.md) (insan eylemi) → K8s auth → Root+Intermediate CA → cert-manager | ✅ script hazır, çalıştırılmayı bekliyor |
| 4 | Control plane: CNPG → gözlemlenebilirlik → OpenCost → Velero (+ Harbor/Keycloak L4'e taşınır) | ⬜ _TBD_ |
| 5 | Kyverno tam guardrail seti (Faz 2'nin 3 politikası → Enforce + 2 etiket daha) | ⬜ _TBD_ |
| 6 | `XTenant` XRD/Composition ([`platform/compositions/tenant/`](platform/compositions/tenant/)) — `crossplane render` ile gerçekten test edildi | ✅ yazıldı ve doğrulandı, cluster'a uygulanmayı bekliyor |
| 7 | `tenant-requests` reposu ve CI doğrulaması | ⬜ _TBD_ |
| 8 | Backstage | ⬜ _TBD_ |

### Faz 1'i çalıştırmak

```bash
cp platform/underlay/.env.example platform/underlay/.env
$EDITOR platform/underlay/.env      # IP havuzu, disk filtresi, parolalar — zorunlu
./platform/bootstrap/01-underlay.sh
```

### Faz 2'yi çalıştırmak

```bash
$EDITOR platform/underlay/.env      # PLATFORM_REPO_URL / PLATFORM_REPO_REVISION ekleyin
./platform/bootstrap/02-control-plane.sh
```

Her iki script de idempotenttir, her adımda readiness bekler ve `.env` eksikse
**hiçbir şey uygulamadan** durur. Doğrulama: `--verify-only`.

**Faz 2'den sonra çoğu şey ArgoCD üzerinden gelir** — ama Faz 1'in devralınması
(`underlay-root` Application) ve Vault (Faz 3'e kadar) bilinçli olarak
otomatik sync'in DIŞINDA tutulur; bkz. [`bootstrap/README.md`](platform/bootstrap/README.md).

---

## Bir tenant nasıl talep edilir (ileride)

1. Backstage'de *Create Tenant* şablonunu çalıştır (veya elle PR aç).
2. `tenant-requests/tenants/<name>.yaml` dosyası oluşur.
3. CI, şema + politika dry-run doğrulaması yapar.
4. Platform ekibi PR'ı onaylar → merge.
5. ArgoCD senkronize eder, Crossplane `XTenant`'ı 14+ kaynağa açar.
6. `kubectl get xtenant <name>` ile durum izlenir.

Örnekler → [`platform/examples/`](platform/examples/)

---

## Kurallar

Kod veya YAML yazmadan önce okunması zorunlu:

- [ADR-0001 — Mimari](platform/docs/adr/0001-architecture.md)
- [Conventions — İsimlendirme & etiketleme](platform/docs/conventions.md)
- [PLATFORM_CONTEXT — Şu an neredeyiz](platform/docs/PLATFORM_CONTEXT.md)

**Her faz sonunda `PLATFORM_CONTEXT.md` güncellenir.** Bu isteğe bağlı değildir.
