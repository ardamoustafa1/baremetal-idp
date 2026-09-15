# L3 — Kimlik & PKI

Platformun güven kökü. `control-plane/`'in **altındadır**: Vault çökerse
control plane kurtarılabilir, tersi mümkün değildir.

| Dizin | İçerik |
|---|---|
| `vault/` | Vault kurulumu (HA), PKI secrets engine, KV v2, Kubernetes auth, tenant policy şablonları |
| `cert-manager/` | cert-manager kurulumu, Vault `ClusterIssuer`, tenant başına `Issuer` şablonu |
| `trust-bundles/` | Kök/ara CA sertifikalarının kümeye dağıtımı (trust-manager `Bundle`) |

**Kritik:** Kök özel anahtar **hiçbir zaman** Kubernetes Secret'ında durmaz.
İmzalama Vault içinde olur. Gerekçe → ADR-0001 Karar 2.3.

**Bekleyen karar:** ~~Vault unseal anahtarlarının (Shamir shares) saklanma
yeri~~ → Faz 3'te çözüldü: [`docs/runbooks/vault-unseal.md`](../docs/runbooks/vault-unseal.md) §2.

Durum: **Faz 3'te yazıldı** (manifestler + `03-pki.sh` + runbook), henüz
hiçbir cluster'a uygulanmadı.

## Faz 3 içeriği

| Alt bölüm | Ne sağlıyor |
|---|---|
| [`vault/README.md`](vault/README.md) | HA/Raft gerekçesi, Root CA izolasyonunun Vault OSS'teki gerçek karşılığı, TLS bootstrap notu |
| `vault/values.yaml` | Vault Helm chart — HA, Raft, 3 replika, ceph-block PV |
| `vault/policies/*.hcl` | cert-manager / crossplane / root-ca-admin (break-glass) policy'leri |
| [`cert-manager/README.md`](cert-manager/README.md) | `serviceAccountRef` neden statik Secret yerine tercih edildi |
| `cert-manager/values.yaml` + `resources/` | cert-manager + 3 ClusterIssuer + (koşullu) ServiceMonitor |
| `cert-manager/test-certificate.yaml.tpl` | Uçtan uca doğrulama için tek seferlik test kaynağı |

Kurulum: [`platform/bootstrap/03-pki.sh`](../bootstrap/03-pki.sh) —
Vault init/unseal **insan eylemidir**, script bunu otomatikleştirmez.
