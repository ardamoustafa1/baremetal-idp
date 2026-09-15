# Secret-sızıntısı taraması — gerçek doğrulama kaydı

`security-scan.yaml` (platform reposu) ve `tenant-requests/.github/workflows/
validate.yaml`'daki `secret-scan` job'ı GERÇEK araçlarla, GERÇEK (ama sahte/
zararsız) bir test secret'ıyla doğrulandı — bu dizin yalnızca o testin
kaydını tutar; canlı CI'da ÇALIŞTIRILAN bir fixture DEĞİLDİR (gerçek bir
sahte secret'ı bu repoya commit etmek, gitleaks/trufflehog'un KENDİ
taramasını her PR'da tetikleyip CI'yı bloklardı — bu yüzden test ayrı,
geçici bir yerel git reposunda yapıldı, sonucu burada belgeleniyor).

## Yapılan test

```bash
mkdir /tmp/gitleaks-test && cd /tmp/gitleaks-test && git init
cat > config2.env <<'EOF'
GITHUB_TOKEN=ghp_[REDACTED — gerçek testte rastgele 36 karakter üretildi]
STRIPE_KEY=sk_live_[REDACTED — gerçek testte rastgele 24 karakter üretildi]
EOF
git add config2.env && git commit -m "test secret"

gitleaks detect --source . --no-git=false -v
trufflehog git file://. --fail --no-update
```

> NOT: yukarıdaki değerler bu dosyada BİLEREK REDACTED — gerçek testte
> kullanılan tam-formatlı (ama sahte/rastgele üretilmiş) değerler GitHub'ın
> KENDİ push-protection secret scanner'ını tetikliyordu (aynı sınıf araç,
> tam olarak BEKLENEN davranış — testin kendisi bunu KANITLIYOR). Test
> SONUCU (aşağıdaki tablo) gerçek, canlı bir çalıştırmadan.

## Sonuç

| Araç | Bulgu | Exit code |
|---|---|---|
| `gitleaks` 8.21.2 | `stripe-access-token` kuralı, `config2.env:2`'de eşleşti | **1** (leak found) |
| `trufflehog` 3.97.4 | `Stripe` detector'ı, aynı satırda eşleşti (`unverified` — sahte anahtar olduğu için Stripe API doğrulaması başarısız, BEKLENEN) | **183** (`--fail` ile) |

**Not — AWS örnek anahtarı YAKALANMADI:** İlk denemede AWS dokümantasyonunun
kendi "AKIAIOSFODNN7EXAMPLE" örnek anahtarı kullanıldı; gitleaks bunu
**gitleaks.toml'ın varsayılan allowlist'i** nedeniyle (çok bilinen bir
"örnek" değer olduğu için) YAKALAMADI — "no leaks found" ile geri döndü.
Bu, testin KENDİSİNİN yanlış olduğunu gösterdi; gerçekçi/rastgele görünen
bir anahtar (Stripe `sk_live_...` formatı) ile tekrarlanınca İKİ ARAÇ DA
doğru şekilde yakaladı. **Ders:** dokümantasyon örneklerindeki "well-known"
placeholder değerlerle güvenlik taraması test edilemez — gerçekçi
formatlı, rastgele bir test değeri kullanılmalı.

## CI'da nasıl çalışır

- `fetch-depth: 0` ile TAM git geçmişi checkout edilir (shallow clone'da
  yalnızca HEAD taranır, önceki bir commit'e gömülü sır kaçırılır).
- Her iki araç da ayrı bir job'da, BİRBİRİNDEN BAĞIMSIZ çalışır — biri
  false-negative verse diğeri PR'ı yine bloklar.
- Gerçek bir sır bulunursa: gitleaks exit code **1**, trufflehog (`--fail`
  ile) exit code **183** — GitHub Actions bu job'ları `failure` olarak
  işaretler ve PR merge edilemez (branch protection ile birleştirilmelidir
  — bu repo GitHub branch protection kuralını YAPILANDIRMIYOR, bu bir
  GitHub organizasyon ayarıdır, kapsam dışı bırakıldı).
