# cert-manager — Vault-backed ClusterIssuer'lar

| Dosya | İçerik |
|---|---|
| `values.yaml` | cert-manager Helm chart değerleri |
| `resources/clusterissuers.yaml` | 3 ClusterIssuer: `vault-issuer-{dev,staging,prod}` |
| `resources/servicemonitor.yaml` | Faz 4 (Prometheus Operator CRD'si) için hazır, koşullu uygulanır |
| `test-certificate.yaml.tpl` | Uçtan uca doğrulama için tek seferlik test kaynağı — **ArgoCD'nin izlediği `resources/` dizininin DIŞINDA**, kalıcı değil |

## Kimlik doğrulama: `serviceAccountRef`, statik Secret DEĞİL

Her `ClusterIssuer.spec.vault.auth.kubernetes`, `secretRef` (uzun ömürlü,
statik bir ServiceAccount token Secret'ı) yerine **`serviceAccountRef`**
kullanır — cert-manager 1.13+'ta eklenen, cert-manager'ın kendi pod
kimliğinin **kısa ömürlü, otomatik yenilenen** bir projected token'ını
(Kubernetes TokenRequest API) Vault'a sunduğu yöntem. Repo'da veya
Vault'ta **hiçbir statik cert-manager token'ı durmaz.**

Neden AppRole değil: Kubernetes auth zaten Faz 3'ün 2. adımında (Vault
Kubernetes Auth Method) kuruldu; aynı mekanizmayı cert-manager için de
kullanmak ikinci bir auth backend'i (AppRole: role_id + secret_id çifti,
bir yerde saklanması gereken bir secret_id ile) işletmekten kaçınır.

## Sertifika yaşam döngüsü

| Ortam | Vault mount | Vault role | Max TTL | ClusterIssuer |
|---|---|---|---|---|
| dev | `pki-int-dev` | `platform-dev` | 90 gün | `vault-issuer-dev` |
| staging | `pki-int-staging` | `platform-staging` | 90 gün | `vault-issuer-staging` |
| prod | `pki-int-prod` | `platform-prod` | 90 gün | `vault-issuer-prod` |

90 gün, ADR-0001 Karar 2.3'teki örnek TTL'dir. cert-manager, sertifikanın
ömrünün 2/3'ünde otomatik yeniler — elle sertifika yenileme operasyonu yok.

## Test

```bash
./platform/bootstrap/03-pki.sh --only cert-test
# veya doğrudan:
kubectl apply -f platform/pki/cert-manager/test-certificate.yaml.tpl   # önce render edilmeli
```

Ayrıntı: `03-pki.sh` içindeki `verify_certificate()` — Certificate CR
uygular, `Ready` bekler, leaf sertifikayı çıkarır, Vault'tan Root+Intermediate
CA zincirini çeker, `openssl verify` ile uçtan uca doğrular, sonra temizler.
