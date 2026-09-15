# Platform — Bare-metal Internal Developer Platform

Bare-metal, çok-kiracılı (multi-tenant), self-servis bir **Internal Developer
Platform**. Ürün ekipleri kendi altyapılarını (namespace, kota, ağ politikası,
veritabanı, registry projesi, secret, sertifika, yedek) **bir PR açarak**
talep eder; platform ekibi ticket işlemez, API sağlar.

> **Mevcut durum (güncellendi):** Faz 1-12h — tüm katmanların (underlay →
> PKI → control plane → guardrail'ler → tenant API → portal) kaynakları
> YAZILDI ve GERÇEK bir kind cluster'ında (Vault+cert-manager+CNPG+
> Crossplane+Kyverno+Velero+MinIO) tekrarlanan e2e/chaos/DR tatbikatlarıyla
> kanıtlandı. **GERÇEK bir bare-metal/üretim cluster'ına HENÜZ hiç
> uygulanmadı** — bu, bu repo'nun geliştirildiği ortamın yapısal bir
> sınırıdır (fiziksel donanım/IP havuzu/DNS yok). "Faz 0" ifadesi ESKİYDİ
> ve bu dosyayla PLATFORM_CONTEXT.md arasındaki bir tutarsızlıktı — düzeltildi.
> Güncel, satır satır durum için → [`platform/docs/PLATFORM_CONTEXT.md`](platform/docs/PLATFORM_CONTEXT.md)
> (bu dosya YALNIZCA özet verir; ayrıntı/kanıt/açık işler için HER ZAMAN
> PLATFORM_CONTEXT.md'ye bakın).

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

Aşağıdaki "Durum" sütunu KASITLI olarak iki farklı şeyi ayırt eder: **"yazıldı
ve kind'da kanıtlandı"** (kod var, gerçek bir kind cluster'ında e2e/chaos/DR
tatbikatlarıyla test edildi) ile **"gerçek bare-metal'de çalışıyor"** (henüz
HİÇBİR adım için doğru değil — bkz. yukarıdaki durum notu). Ayrıntı/kanıt
için her satır PLATFORM_CONTEXT.md'nin ilgili Faz günlüğüne bağlanır.

| Adım | Ne yapılır | Durum |
|---|---|---|
| 0 | Ön koşullar: node'lar, kube-proxy'siz kubeadm, ham diskler, DNS, MetalLB IP havuzu | 📋 [underlay/README.md](platform/underlay/README.md#ön-koşullar) — GERÇEK donanım bu ortamda yok |
| 1 | Underlay + Keycloak + Harbor: `./platform/bootstrap/01-underlay.sh` | ✅ yazıldı, kind'da kanıtlandı — gerçek bare-metal'de HENÜZ çalıştırılmadı |
| 2 | ArgoCD + App-of-Apps + Crossplane + Kyverno + ESO + **CNPG**: `./platform/bootstrap/02-control-plane.sh` | ✅ yazıldı, kind'da kanıtlandı (CNPG: Faz 12h, GitOps zincirine yeni bağlandı) |
| 3 | PKI: `./platform/bootstrap/03-pki.sh` — Vault (HA/Raft) → [init/unseal](platform/docs/runbooks/vault-unseal.md) (insan eylemi) → K8s auth → Root+Intermediate CA → cert-manager → **Vault listener TLS'i (kendi PKI'sinden)** | ✅ yazıldı, kind'da kanıtlandı (TLS adımı: Faz 12g/12h, statik doğrulandı — gerçek bir HTTPS handshake bu ortamda KANITLANMADI) |
| 4 | Control plane: gözlemlenebilirlik + OpenCost + **Velero**: `./platform/bootstrap/05-observability.sh`, `./platform/bootstrap/06-velero.sh` (+ Harbor/Keycloak Faz 1'de) | ✅ yazıldı; Velero (Faz 12h): OBC→Secret→helm→GERÇEK bir on-demand backup zinciri tasarlandı ama bu ortamda ÇALIŞTIRILMADI |
| 5 | Kyverno tam guardrail seti — taban hijyeni (01-03, Audit) + Tenant guardrail'leri (04-10, doğrudan Enforce) | ✅ 10 ClusterPolicy yazıldı, `kyverno test` ile 38/38 senaryo doğrulandı |
| 6 | `XTenant`/`XPostgreSQLInstance` XRD/Composition ([`platform/compositions/`](platform/compositions/)) | ✅ yazıldı, `crossplane render` + GERÇEK kind cluster'ında Tenant→Postgres→bağlantı→cert zinciriyle kanıtlandı |
| 7 | `tenant-requests` reposu (bu repoda İSKELET, bkz. altındaki not) ve CI doğrulaması | ✅ iskelet + ApplicationSet + RBAC/Kyverno claim koruması yazıldı — CANLIYA ALINIRKEN ayrı bir Git reposuna taşınmalı |
| 8 | Backstage (portal + scaffolder template'i + gerçek tenant-ownership yetkilendirmesi, Faz 12g) | ✅ yazıldı — `tsc --noEmit` ile tip-doğrulandı, GERÇEK bir kullanıcı girişiyle UÇTAN UCA denenmedi |

### Faz 1'i çalıştırmak

```bash
cp platform/underlay/.env.example platform/underlay/.env
$EDITOR platform/underlay/.env      # IP havuzu, disk filtresi, parolalar — zorunlu
./platform/bootstrap/01-underlay.sh
```

### Faz 2'yi çalıştırmak

```bash
$EDITOR platform/underlay/.env      # PLATFORM_REPO_URL / PLATFORM_REPO_REVISION ekleyin

# ZORUNLU tek seferlik adım (Faz 12i, code review #1 — KRİTİK): ArgoCD'nin
# root Application'ı .tpl dosyalarını OKUYAMAZ (yalnızca .yaml/.yml/.json) —
# bu script gerçek .yaml kardeşlerini üretir. Detay: bootstrap/README.md.
export PLATFORM_REPO_URL="https://github.com/<org>/<repo>.git"
export PLATFORM_REPO_REVISION="main"
./platform/bootstrap/render-app-manifests.sh
git add platform/control-plane/apps platform/bootstrap/app-of-apps/underlay platform/policies/security
git commit -m "chore: app manifestlerini render et"

./platform/bootstrap/02-control-plane.sh
```

### Faz 3'ü çalıştırmak (PKI)

```bash
./platform/bootstrap/03-pki.sh
# script Vault'u init/unseal edilmemiş bulursa DURUR ve
# docs/runbooks/vault-unseal.md'ye yönlendirir (insan eylemi) — bittikten
# sonra aynı komutu tekrar çalıştırın.
```

### Faz 12h'yi çalıştırmak (Velero — Faz 1-3'ten SONRA, herhangi bir sırada)

```bash
$EDITOR platform/underlay/.env      # VELERO_OFFSITE_* — isteğe bağlı ama üretimde önerilir
./platform/bootstrap/06-velero.sh
```

Tüm script'ler idempotenttir, her adımda readiness bekler ve `.env` eksikse
**hiçbir şey uygulamadan** durur. Doğrulama: `--verify-only`.

**Faz 2'den sonra çoğu şey ArgoCD üzerinden gelir** — ama Faz 1'in devralınması
(`underlay-root` Application), Vault ve Velero (S3 sırrı Git'e yazılamadığı
için) bilinçli olarak otomatik sync'in DIŞINDA tutulur; bkz.
[`bootstrap/README.md`](platform/bootstrap/README.md).

---

## Bir tenant nasıl talep edilir

Akışın TÜM parçaları (ApplicationSet, RBAC/Kyverno claim koruması, Crossplane
composition'ı) yazıldı ve kind'da kanıtlandı — ama gerçek bir kullanıcının
gerçek bir Keycloak girişiyle bu akışı uçtan uca denediği bir tatbikat HENÜZ
yapılmadı (bkz. yukarıdaki durum notu, madde 6).

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
