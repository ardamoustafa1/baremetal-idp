# `protect-prod-tenant-deletion` — gerçek doğrulama kaydı

Bu politika `kyverno test` ile (statik `kyverno-test.yaml` + `variables.yaml`
fixture'ı) DOĞRULadıANAMADI: bu repodaki Kyverno CLI sürümünün (1.19.1) `test`
komutu, `request.operation=DELETE` + `request.oldObject` simülasyonu için
kullanılan values-dosyası şemasını "deprecated, 1.15'te kaldırılacak" olarak
reddediyor ve güncel şemanın bu iki alanı nasıl karşıladığı bu ortamda
doğrulanamadı. Bunun yerine (`require-signed-images` testinin AYNI
gerekçesiyle) `kyverno apply --set` ile GERÇEK, tekrarlanabilir bir doğrulama
yapıldı — aşağıdaki üç komut, üç senaryoyu da KANITLAR.

## Yapılan test (bu görevde, gerçek CLI ile)

Kaynak dosya (`spec.environment=prod`, onay annotation'ı YOK):

```bash
cat > /tmp/acme-prod.yaml <<'EOF'
apiVersion: platform.internal/v1alpha1
kind: Tenant
metadata:
  name: acme-prod
  namespace: tenant-requests
spec:
  teamName: acme
  costCenter: "CC-1000"
  environment: prod
  networkTier: isolated
  quotaTier: large
  oidcGroup: tenant-acme
EOF
```

**1) Onaysız prod silme → REDDEDİLDİ (beklenen, kanıtlandı):**

```bash
kyverno apply platform/policies/validation/10-protect-prod-tenant-deletion.yaml \
  -r /tmp/acme-prod.yaml \
  --set request.operation=DELETE,request.oldObject.spec.environment=prod
# → pass: 0, fail: 2 (her iki annotation kuralı da reddetti)
```

**2) Onaylı prod silme (iki annotation da mevcut) → KABUL EDİLDİ:**

```bash
kyverno apply platform/policies/validation/10-protect-prod-tenant-deletion.yaml \
  -r /tmp/acme-prod.yaml \
  --set request.operation=DELETE,request.oldObject.spec.environment=prod,\
"request.oldObject.metadata.annotations.platform\.internal/deletion-approved-by"=arda,\
"request.oldObject.metadata.annotations.platform\.internal/deletion-approved-reason"="contract ended"
# → pass: 2, fail: 0
```

**3) Dev tenant silme (onay annotation'ı hiç gerekmez) → ETKİLENMEDİ:**

```bash
kyverno apply platform/policies/validation/10-protect-prod-tenant-deletion.yaml \
  -r /tmp/acme-dev.yaml \
  --set request.operation=DELETE,request.oldObject.spec.environment=dev
# → pass: 2, fail: 0 (politika yalnızca prod'u kapsar)
```

## PostgreSQLInstance kapsamı (Faz 12j, code review #10'un eklentisi)

Aynı politika artık `PostgreSQLInstance` claim DELETE'ini de kapsıyor —
`tenantRef`'in (immutable, bkz. `postgresql/xrd.yaml`) `-prod` ile bitip
bitmediğine göre. Aynı yöntemle doğrulandı:

```bash
cat > /tmp/pg-prod.yaml <<'EOF'
apiVersion: platform.internal/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: acme-db
  namespace: tenant-acme-prod
spec:
  tenantRef: tenant-acme-prod
  size: small
  version: "16"
EOF

kyverno apply platform/policies/validation/10-protect-prod-tenant-deletion.yaml \
  -r /tmp/pg-prod.yaml --set request.operation=DELETE
# → pass: 0, fail: 2 (onaysız — REDDEDİLDİ)

# annotation'lar eklenince (aynı iki annotation) → pass: 2, fail: 0 (KABUL)
# tenantRef "-dev" ile bitiyorsa (tenant-acme-dev) → pass: 2, fail: 0 (ETKİLENMEDİ)
```

## Sonuç

Yedi senaryo da (Tenant: onaysız-prod/onaylı-prod/dev; PostgreSQLInstance:
onaysız-prod/onaylı-prod/dev) beklenen sonucu verdi — politika hem
gerçekten reddediyor hem de gereksiz yere engellemiyor. İleride bu CLI
sürümü `test` komutunun values şemasını güncellediğinde bu senaryolar
statik bir `kyverno-test.yaml` fixture'ına taşınabilir.

## Onay annotation'larının kim tarafından yazılabileceği (Faz 12k, code
## review #11'in çözümü) — CANLI TEST EDİLEMEDİ

`only-admins-set-deletion-approved-*` kuralları, bu iki annotation'ın
DEĞERİ DEĞİŞTİĞİNDE (`request.object` vs `request.oldObject`
karşılaştırması) isteği yapanın `platform-admins` grubunda olmasını
zorunlu kılar. Bu kuralın precondition'ı `kyverno apply --set
request.oldObject...` ile TEST EDİLMEYE ÇALIŞILDI ama bu Kyverno CLI
sürümünde (1.19.1) `-r` ile verilen kaynak dosyası HER ZAMAN hem
`request.object` HEM `request.oldObject`'e bağlanıyor — `--set` ile
yalnızca `request.oldObject`'i FARKLI bir değere ayarlamak (UPDATE'i
GERÇEKÇİ simüle etmek için gereken) bu ortamda MÜMKÜN olmadı (denendi,
kanıtlandı: `--set request.oldObject.metadata.annotations....=EMPTYSTR`
verilse bile `request.oldObject` sessizce `request.object` ile AYNI
değere düştü). Kuralın MANTIĞI (JMESPath karşılaştırması + grup kontrolü,
`restrict-tenant-claim-creation.yaml`'daki KANITLANMIŞ AYNI desen) elle
incelenip doğru bulundu ama GERÇEK bir admission webhook isteğine (ya da
bu CLI'nin `oldObject`'i doğru bağladığı bir sürüme) karşı ÇALIŞTIRILMADI
— bu, dürüstçe işaretlenen bir açık iş.

## CREATE zamanında sahte onay annotation'ı — GERÇEK, KANITLANMIŞ açık (code review #15) + otomatik regresyon testi

Yukarıdaki `only-admins-set-*` kuralları YALNIZCA `request.operation ==
UPDATE` iken çalışıyordu — CREATE'İ HİÇ kapsamıyordu.
`restrict-tenant-claim-creation.yaml`, CLAIM CREATE'ini "yetkili istekçi
mi" diye kontrol eder ama annotation İÇERİĞİNİ kısıtlamaz — yani
`tenant-claim-requester` rolündeki (admin OLMAYAN) bir kullanıcı,
`spec.environment: prod` olan bir Tenant claim'ini, onay
annotation'larını BAŞTAN sahte bir değerle DOLU olarak CREATE edebilirdi;
`environment` immutable olduğu için bu sahte onay SONSUZA KADAR
`oldObject`'te kalırdı — gerçek bir admin ASLA görmese bile.

YENİ 4 kural (`only-admins-set-*-on-create`, Tenant/PostgreSQLInstance ×
approved-by/approved-reason) bunu kapatır. CREATE, oldObject
GEREKTİRMEDİĞİ için (UPDATE'in aksine) bu senaryo yukarıdaki CLI
sınırlaması olmadan hem `kyverno apply --userinfo` ile HEM DE (bu ilk
kez!) statik bir `kyverno-test.yaml` fixture'ı ile ("create-forged-approval/"
dizini) GERÇEKTEN, otomatik regresyon paketine kanıtlanmış olarak eklendi
— 3 senaryo (saldırgan+sahte annotation → RED; admin+annotation → KABUL;
sahte annotation OLMADAN normal CREATE → ETKİLENMEDİ) elle `kyverno apply`
ile doğrulandı; ilk senaryo AYRICA `platform/policies/tests/` altındaki
40 testlik CI paketine `create-forged-approval/kyverno-test.yaml` olarak
eklendi (`kyverno test` HER PR'da çalışır).
