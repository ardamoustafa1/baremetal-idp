# Üretime geçiş ve kabul

## Mevcut durum

Kod düzeltmeleri gerçek hedef kümeye uygulanmadan üretim hazır sayılmaz.
Bu çalışma alanında Kubernetes context yoktur. Harbor image registry/tag
alanları da `REPLACE_ME` durumundadır; bunların gerçek değerleri operatörden
alınmalıdır. Hiçbir gerçek adres, sır, başarılı restore veya onay uydurulmaz.

## 1. Yerel doğrulama

```bash
python3 -m unittest discover -s platform/tests/readiness -p 'test_*.py'
python3 tenant-requests/.github/scripts/test-validation.py
kyverno test platform/policies/tests/
cd platform/backstage/portal
node .yarn/releases/yarn-4.13.0.cjs install --immutable
node .yarn/releases/yarn-4.13.0.cjs tsc
node .yarn/releases/yarn-4.13.0.cjs workspace backend test --watch=false --runInBand
```

## 2. Ortamı somutlaştırma

- Test kubeconfig/context, platform ve tenant-requests repo adresleri, DNS,
  image registry/tag ve dış S3 hedefi belirlenir.
- Secret değerler Git’e yazılmaz. Backstage `configure.py` ile sır olmayan
  hedefler ve GitOps manifestleri üretilir. Image build edilir, taranır ve
  mevcut imza pipeline’ından geçirilir.
- Kopia parolası bağımsız güvenli dosyada saklanır;
  `VELERO_REPOSITORY_PASSWORD_FILE` ilk kurulumda bu dosyayı gösterir.
- Her Bound PVC için veri sahibi, yedek yöntemi, RPO/RTO ve geri yükleme
  komutu kaydedilir. FSB için pod volume annotation’ı uygulanır. Canlı
  veritabanları için native backup veya uygulamaya uygun durdurma hook’u
  gerekir. Annotation eklemek tek başına veri tutarlılığı sağlamaz.

## 3. Test ortamına uygulama

Hedef context açıkça seçildikten sonra sırayla:

1. `03-pki.sh --only vault-tls`: TLS/CA güncellemesi, sıralı restart.
2. Güncel Tenant XRD ve portal image/config/templates GitOps ile uygulanır.
3. `05-observability.sh`: Vault sertifika probe’u ve alarm kuralları.
4. `06-velero.sh`: node-agent, yedek planları ve dış kopya.
5. PostgreSQL image kontrolü `COSIGN_PUBLIC_KEY` ile
   `verify-harbor-image-exists.sh --require-signature` üzerinden çalıştırılır.

Var olan claim’lerde eksik `oidcGroup` varsa XRD güncellemesinden önce doğru
Keycloak grubuyla tamamlanmalıdır. Varsayılan veya tahmin edilmiş bir grup
atanmaz. Portalın eski e-posta tabanlı giriş resolver’ı config’ten kaldırılmalı;
Keycloak UserInfo `groups` claim’i doğrulanmalıdır.

## 4. Gerçek kabul testleri

- **OIDC:** Sahip/başka tenant/admin/gruptan çıkarılmış kullanıcı; doğrudan
  API ve form isteği, görev geçmişi, yeniden token alma. Tenant’ın başka
  tenantRef göndermesi reddedilmeli. Grup iptalinde 10 dakikalık mevcut
  token penceresi ölçülmeli.
- **Vault:** Sertifika yenileme, lider değişimi, test kümesinde yeni boş
  diskli üyenin katılması, ESO ve cert-manager’ın yeniden kimlik doğrulaması.
  Üretim PVC’si bu test için silinmez.
- **Veri:** Bilinen satır/dosya ekle; yedek al; kaynak sisteme erişmeyen ayrı
  test ortamına dış hedeften geri yükle; satır/dosya içeriğini karşılaştır.
  PostgreSQL için belirli zamana dönüş ve WAL erişimi de doğrulanmalı.
  Kopia repo parolası ve Vault kurtarma materyali ayrı konumdan sağlanmalı.
- **Alarm:** Kontrollü test arızasının Alertmanager üzerinden gerçek alıcıya
  ulaştığını ve düzelince kapandığını kontrol et. Sır içermeyen kanıt sakla.

## 5. Son kontrol

```bash
python3 platform/tests/readiness/check-live.py \
  --context TEST_CONTEXT \
  --acceptance /secure/release/acceptance.json \
  --output /tmp/platform-readiness.json
```

`--acceptance` verilmezse canlı kabul maddeleri başarısız kalır. Dosya,
`context`, `revision` (test edilen Git SHA) ve `scenarios` nesnesi içerir.
Senaryolar: `oidc-four-users`, `postgres-offsite-pitr`,
`vault-replacement-renewal`, `alert-delivery`. Her sonuç `passed`,
`checkedAt` (UTC ISO tarih), `reviewedBy`, `evidenceFile` alanlarını taşır;
kanıt dosyası rapora göre göreli bir yoldur. Başarılı değerler ancak test
sonrasında yazılır. Yedi günden eski veya başka revision/context’e ait
kanıt kabul edilmez. Rapor çalışma ağacındaki yeni değişiklikleri doğrulamaz;
son test öncesi incelenmiş değişiklikler commit edilmelidir.

Bu araç Secret içeriği okumaz. Yakın tarihli yedek, PVC kapsamı, node-agent,
Argo sağlık/senkron ve restore durumunu kontrol eder. Gerçek uygulama veri
kontrolünün yerini tutmaz. FSB/CNPG dışı native yedeklerin kapsamı manuel
incelenmeli; açık PVC satırları yok sayılarak otomatik PASS üretilmemelidir.
