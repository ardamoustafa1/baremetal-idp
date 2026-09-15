# `protect-prod-tenant-deletion` — gerçek doğrulama kaydı

Bu politika `kyverno test` ile (statik `kyverno-test.yaml` + `variables.yaml`
fixture'ı) DOĞRULANAMADI: bu repodaki Kyverno CLI sürümünün (1.19.1) `test`
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

## Sonuç

Üç senaryo da beklenen sonucu verdi — politika hem gerçekten reddediyor
(onaysız prod) hem de gereksiz yere engellemiyor (dev, onaylı prod).
İleride bu CLI sürümü `test` komutunun values şemasını
güncellediğinde bu üç senaryo statik bir `kyverno-test.yaml` fixture'ına
taşınabilir.
