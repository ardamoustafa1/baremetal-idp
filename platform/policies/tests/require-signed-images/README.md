# `require-signed-images` — gerçek uçtan uca doğrulama kaydı

Bu politika `kyverno test` ile (statik YAML fixture) DOĞRULANAMAZ çünkü
`verifyImages` bir OCI registry'ye GERÇEKTEN ağ çağrısı yapar (imza arar).
Bu yüzden doğrulama, `kyverno apply --registry` ile GERÇEK bir registry'ye
karşı, GERÇEK cosign anahtarlarıyla yapıldı — aşağıda tekrarlanabilir.

## Yapılan test (bu görevde, gerçek araçlarla)

1. Yerel bir Docker registry (`registry:2`, `localhost:5555`) ayağa kaldırıldı.
2. `cosign generate-key-pair` ile gerçek bir anahtar çifti üretildi.
3. `alpine:3.20` iki farklı tag ile push edildi: `signed-app:v1` ve
   `unsigned-app:v1`.
4. Yalnızca `signed-app:v1`, `cosign sign --key cosign.key` ile imzalandı.
5. `01-require-signed-images.yaml.tpl`'ın bir türevi (`publicKeys` inline, Secret
   yerine — cluster'sız `kyverno apply` Secret çözemez) her iki imaja karşı
   `kyverno apply policy-test.yaml --resource <pod>.yaml --registry` ile
   çalıştırıldı:
   - **İmzalı imaj → `pass: 2, fail: 0`** (Pod + otomatik üretilen CronJob kuralı)
   - **İmzasız imaj → `pass: 0, fail: 2`**, hata: `no signatures found`

## KRİTİK BULGU: cosign v3.x ile Kyverno 1.19.1 UYUMSUZ

İlk denemede `cosign` (Homebrew'in verdiği v3.1.3) ile imzalanan imaj bile
Kyverno tarafından **REDDEDİLDİ** ("no signatures found") — imza gerçekten
vardı ve `cosign verify` bunu doğruluyordu, ama Kyverno göremiyordu.

**Kök neden:** cosign v3.1.3, imzayı VARSAYILAN olarak OCI 1.1 "Referrers
API" üzerinden bir sigstore-bundle (`dev.sigstore.bundle.v0.3+json`,
DSSE-envelope) olarak yazıyor. `--registry-referrers-mode=legacy` verilse
bile İÇERİK FORMATI hâlâ yeni bundle şeması. Kyverno 1.19.1'in gömülü
cosign doğrulama kütüphanesi yalnızca ESKİ `sha256-<digest>.sig` etiket
kuralını VE eski (bundle-öncesi) imza payload biçimini anlıyor.

**Çözüm (bu testte doğrulandı):** cosign v2.4.1 (GitHub release'inden
doğrudan indirilen statik binary — Homebrew yalnızca v3.x veriyor) ile
İMZALANAN aynı imaj, Kyverno tarafından **KABUL EDİLDİ** (`pass: 2`).

**Sonuç/aksiyon:** CI'daki imza atma adımı (`image-supply-chain.yaml`)
cosign'ı **v2.4.1'e SABİTLER** (bkz. o workflow'un `COSIGN_VERSION` pin'i) —
`cosign-installer` action'ının `latest` almasına KESİNLİKLE izin verilmez.
Bu, PLATFORM_CONTEXT.md'ye teknik borç olarak da kaydedildi (cosign v3
genelleştiğinde Kyverno'nun da güncellenmesi/yeni bundle formatını
desteklemesi gerekecek).

## Yeniden üretme

```bash
docker run -d -p 5555:5000 --name test-registry registry:2
cosign generate-key-pair   # cosign.key / cosign.pub üretir
docker pull alpine:3.20
docker tag alpine:3.20 localhost:5555/test/signed-app:v1
docker tag alpine:3.20 localhost:5555/test/unsigned-app:v1
docker push localhost:5555/test/signed-app:v1
docker push localhost:5555/test/unsigned-app:v1

# GitHub'dan v2.4.1 statik binary indirilmeli (brew yalnızca v3.x verir):
curl -sL -o cosign2 https://github.com/sigstore/cosign/releases/download/v2.4.1/cosign-darwin-arm64
chmod +x cosign2
COSIGN_PASSWORD="" ./cosign2 sign --key cosign.key --tlog-upload=false --yes localhost:5555/test/signed-app:v1

kyverno apply policy-test.yaml --resource pod-signed.yaml   --registry   # pass: 2
kyverno apply policy-test.yaml --resource pod-unsigned.yaml --registry   # fail: 2
```

`policy-test.yaml`, üretim politikasının (`../../security/01-require-signed-images.yaml.tpl`)
`attestors[0].entries[0].keys.secret` alanı yerine `publicKeys` (inline PEM)
kullanan bir türevidir — yalnızca cluster'sız yerel test için; üretimde
Secret referansı KULLANILMALIDIR (özel anahtarın asla Git'e girmemesi için
zorunlu değil ama public anahtarın da bir ConfigMap/Secret'tan okunması,
Kyverno ClusterPolicy'sini SÜRÜM KONTROLÜNDEN geçmeden değiştirmeden anahtar
rotasyonuna izin verir).
