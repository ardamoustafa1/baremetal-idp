# L4 — Platform Servisleri

Tenant'ların tüketeceği yetenekler. Her biri kendi namespace'inde, Keycloak ile
OIDC entegre (Faz 4), Vault'tan secret alır (Faz 3), Prometheus'a metrik verir (Faz 4).

| Dizin | Bileşen | Sağladığı yetenek | Durum |
|---|---|---|---|
| `argocd/` | ArgoCD | GitOps uzlaşma motoru — Faz 2'den sonra her şeyi yönetir | ✅ Faz 2 |
| `apps/` | ArgoCD Application'ları (App-of-Apps) | sync-wave sıralı katman senkronizasyonu | ✅ Faz 2 |
| `crossplane/` | Crossplane v2 + provider'lar + `function-kcl` | Tenant API çalışma zamanı | ✅ Faz 2 |
| `kyverno/` | Kyverno Helm values | (ClusterPolicy'ler `../policies/validation/`'da) | ✅ Faz 2 |
| `external-secrets/` | External Secrets Operator (yalnızca operatör) | Vault → küme secret yansıtması — SecretStore Faz 3'te | ✅ Faz 2 |
| `keycloak/` | Keycloak | OIDC kimlik sağlayıcı | Faz 1 (bkz. teknik borç #8) |
| `harbor/` | Harbor | Konteyner registry, tenant başına proje, imaj tarama | Faz 1 (bkz. teknik borç #8) |
| `cloudnative-pg/` | CloudNativePG operatörü | Tenant veritabanları (HA, PITR) | ✅ Faz 12h |
| `observability/` | kube-prometheus-stack + Loki + Tempo | Metrik, log, trace, uyarı, Grafana (tenant dashboard'ları otomatik) | ✅ Faz 9 |
| `opencost/` | OpenCost | `cost-center` etiketine dayalı, bare-metal manuel fiyatlandırmalı maliyet raporu | ✅ Faz 9 |
| `velero/` | Velero (Ceph RGW backend + isteğe bağlı küme-dışı ikincil hedef) | Yedekleme ve geri yükleme | ✅ Faz 12h |

**Bağımlılık:** `underlay/` (L2). `pki/` (L3, Vault) henüz yok — ESO ve
Crossplane şu an secret'sız çalışıyor, bu Faz 3'ün konusu.

**Kurulum:** [`platform/bootstrap/02-control-plane.sh`](../bootstrap/02-control-plane.sh)

---

## App-of-Apps yapısı (Faz 2)

```
control-plane/root-app.yaml.tpl          ← 02-control-plane.sh tarafından elle uygulanır
  └── control-plane/apps/                ← ArgoCD bunu git'ten SÜREKLİ izler
        ├── 00-underlay.yaml.tpl                wave 0 — otomatik sync KAPALI (adoption)
        ├── 01-crossplane.yaml.tpl              wave 1 ─┐
        ├── 01-kyverno.yaml.tpl                 wave 1  │
        ├── 01-eso.yaml.tpl                     wave 1  │
        ├── 01-cnpg.yaml.tpl                    wave 1  ├─ paralel, birbirine bağımlı değil
        ├── 01-kube-prometheus-stack.yaml.tpl   wave 1  │  (Faz 9, otomatik sync AÇIK — sır yok)
        ├── 01-loki.yaml.tpl                    wave 1  │  (Faz 9, otomatik sync KAPALI — S3 sırrı)
        ├── 01-tempo.yaml.tpl                   wave 1 ─┘  (Faz 9, otomatik sync KAPALI — S3 sırrı)
        ├── 02-vault-placeholder.yaml.tpl       wave 2 — otomatik sync KAPALI (Faz 3'e kadar)
        ├── 02-velero.yaml.tpl                  wave 2 — otomatik sync KAPALI (Faz 12h, S3 sırrı)
        └── 02-opencost.yaml.tpl                wave 2 — otomatik sync AÇIK (Faz 9, sır yok)
```

Neden `underlay-root`/`vault`/`loki`/`tempo`/`velero` otomatik sync'siz: bkz. bu
dosyaların kendi içindeki uyarı yorumları ve
[`bootstrap/README.md`](../bootstrap/README.md).

**Crossplane/Kyverno/ESO/kube-prometheus-stack/OpenCost neden otomatik sync
güvenli:** Git'te commit edilen values dosyalarında GERÇEK SIR yok (Grafana
admin parolası/Alertmanager webhook'u/OpenCost fiyat ConfigMap'i ayrı, .env
kaynaklı Secret/ConfigMap'lerle DIŞARIDAN bağlanır — bkz.
[`bootstrap/05-observability.sh`](../bootstrap/05-observability.sh)).
Loki/Tempo ise S3 kimlik bilgilerini DOĞRUDAN values dosyasına gömdüğü için
(Rook OBC'den okunan gerçek sır) bu istisnadır.
