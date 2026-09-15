# Yerel kabul kanıtları — 2026-09-14

- Backstage 1.54.0, Node 24.11.1: dependency install, TypeScript check, frontend/backend build başarılı.
- Gerçek `fetch:template` ve `publish:github:pull-request` action'ları iki form için çalıştı. GitHub **client test double** üzerinden PR payload içindeki dosya yolu/base64 içerik/PR çıktısı doğrulandı. İki üretilen Claim **gerçek** crossplane 2.5.0 + Docker/function-kcl, kubeconform 0.8.0, Kyverno 1.19.1 kontrollerinden geçti.
- Mevcut 4 Claim'in tamamı schema/render/policy kontrolünden geçti.
- Geçersiz tier, prod+small, bilinmeyen spec alanı reddedildi (exit=1). PSS privileged namespace policy dry-run reddedildi.
- `kyverno test platform/policies/tests/`: 33 başarılı, 0 başarısız.
- EntityProvider Jest testi: Ready kaydını ekleme, hazır olmayınca çıkarma, API hatasında snapshot koruma başarılı.
- Frontend App Jest render testi başarılı; upstream jsdom Canvas/React deprecation uyarıları mevcut.
- Helm 2.6.1 `helm template` çıktısındaki 3 kaynak kubeconform ile geçerli.
- `actionlint` her iki GitHub Actions workflow'u için temiz.
- `configure.py` izole geçici kopyada test edildi: sabit PR repo hedefi, User, ConfigMap, ArgoCD .yaml manifestleri üretildi.
- Bootstrap shell syntax ve YAML parse kontrolleri geçti.

Canlı GitHub PR, GitHub-hosted Actions koşumu, Kubernetes provision ve gerçek Keycloak oturumu **yapılmadı**. `kubectl config get-contexts -o name` boş; repo/domain/kimlik bilgileri sağlanmadı. Bu sonuçlar canlı kurulum onayı değildir. Kurulum ve canlı kabul adımları README'dedir.
