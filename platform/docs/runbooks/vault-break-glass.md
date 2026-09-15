# Runbook: Vault Break-Glass — Root Token Rotasyonu

| Alan | Değer |
|---|---|
| Kapsam | `platform/pki/vault/` — root token yaşam döngüsü (üretim, kullanım, iptal, acil rotasyon) |
| Sıklık | Zorunlu: her bootstrap sonrası hemen. Planlı: yılda 1 (re-key ile birlikte). Acil: token tehlikeye girdiğinde/kaybedildiğinde. |
| Önkoşul | Vault unsealed, en az 3 key custodian'a erişilebilir (bkz. [`vault-unseal.md`](vault-unseal.md) §2 custodian şeması) |
| İlişkili dosya | `docs/runbooks/vault-unseal.md` (init/unseal/re-key genel prosedürü — BU dosya yalnızca root token'a ODAKLANIR ve o dosyanın eski §6.3'ünün YERİNE GEÇER) |

> **SAPMA NOTU:** `vault-unseal.md`'nin §6.3'ü ("Root token kaybı") zaten
> kısa bir versiyonunu içeriyordu. Bu görev, bunu AYRI ve DAHA DETAYLI bir
> dosyaya (bu dosya) taşımayı istedi — `vault-unseal.md` §6.3 artık bu
> dosyaya bir POINTER'dır (içerik burada TEK doğruluk kaynağı, iki dosyada
> senkronsuz kopya YOK).

---

## 1. Neden root token'ın KENDİSİ bir break-glass konusu

Root token, Vault'un TÜM policy kontrollerini BYPASS eden, sınırsız yetkili
tek bir kimlik bilgisidir. Bu yüzden:
- Normal operasyonda **HİÇ VAR OLMAMALIDIR** (init sonrası hemen iptal edilir).
- Yeniden üretilmesi (`generate-root`), Shamir eşiğini (3/5) sağlayan
  custodian'ların **ortak eylemini** gerektirir — tek kişi asla üretemez.
- Her üretim, bir **olay kaydı (incident ticket)** ile izlenmelidir — kim,
  ne zaman, neden ürettiği denetlenebilir olmalıdır (bkz. §4, Vault audit
  log ile çapraz doğrulama).

---

## 2. Rutin durum: root token YOK

`03-pki.sh`'in ilk bootstrap'ından hemen sonra:

```bash
vault token revoke -self
```

çalıştırılmış olmalıdır (bkz. `vault-unseal.md` §5). Bu runbook'un geri
kalanı, **bu adım atlanmışsa veya root token yeniden gerekiyorsa** geçerlidir.

**Doğrulama (root token'ın GERÇEKTEN olmadığını kontrol edin):**

```bash
# Bu komut, script'in kendi ürettiği (yalnızca bootstrap için) root token
# ile DEĞİL, sizin şu an export ettiğiniz VAULT_TOKEN ile çalışır:
vault token lookup 2>&1 | grep -i "policies" | grep -q root \
  && echo "⚠️  UYARI: şu an root token kullanıyorsunuz — günlük operasyonda BU OLMAMALI" \
  || echo "✅ root değil (beklenen)"
```

---

## 3. Acil root token üretimi (break-glass)

### 3.1 Aktivasyon şartı

**En az iki** yetkilinin (Platform Ekibi Lideri + Güvenlik Sorumlusu, veya
eşdeğer) ortak onayı OLMADAN bu prosedür BAŞLATILMAZ. Tek kişi kararıyla
root token üretilmez — bu, Shamir'in tüm amacını (tek kişinin sistemi ele
geçirememesi) boşa çıkarır.

### 3.2 Adımlar

```bash
# 0. Onay: en az iki yetkili, bir olay kaydı açar (gerekçe: neden root
#    token gerekiyor — örn. "auth/kubernetes rolü bozuldu, elle düzeltme
#    gerekiyor" gibi SOMUT bir neden; "her ihtimale karşı" GEÇERLİ bir
#    gerekçe DEĞİLDİR).

# 1. Üretimi başlat (herhangi bir custodian veya operatör çalıştırabilir —
#    bu adımın kendisi hassas değildir, yalnızca bir "nonce" ve "otp" üretir):
vault operator generate-root -init
# Çıktı: Nonce ve OTP (One-Time Password) değerlerini not edin (bunlar
# GİZLİ DEĞİL — nonce bir oturum kimliğidir, OTP son adımda token'ı
# decode etmek için kullanılır, kendisi yetki VERMEZ).

# 2. EN AZ 3 custodian, KENDİ unseal key parçasıyla katkıda bulunur (her biri
#    KENDİ terminalinde, KENDİ parçasını girer — parçalar asla tek bir
#    kişide birleşmez):
vault operator generate-root -nonce=<1. adımdaki nonce>
# (İstenince kendi Shamir key parçasını girer)

# 3. Eşik (3) sağlanınca Vault, base64 kodlu bir "encoded token" üretir.
#    Bunu OTP ile decode edin (yalnızca prosedürü BAŞLATAN kişi/operatör
#    yapar):
vault operator generate-root -decode=<encoded token> -otp=<1. adımdaki OTP>
# Çıktı: YENİ root token. Bu, TERMİNALDE GÖRÜNÜR — hiçbir dosyaya
# yazılmaz, kopyalanmaz, Slack/e-posta'ya YAPIŞTIRILMAZ.

# 4. Yeni token'ı SADECE gerekli acil müdahale için kullanın:
export VAULT_TOKEN=<yeni token>
# ... (yalnızca olay kaydındaki SOMUT düzeltme adımı) ...

# 5. Müdahale bitince DERHAL iptal edin:
vault token revoke -self
unset VAULT_TOKEN
```

### 3.3 Sonrası — ZORUNLU adımlar

1. **Olay kaydını kapatın**: ne yapıldığı, hangi custodian'ların katıldığı,
   root token'ın ne kadar süre AKTİF kaldığı (adım 1→5 arası süre)
   kaydedilir.
2. **Audit log'u çapraz kontrol edin** (bkz. §4) — root token ile yapılan
   HER işlem, `03-pki.sh`'in etkinleştirdiği `file` audit device'ında
   görünmelidir; olay kaydındaki adımlarla EŞLEŞMEYEN bir işlem varsa bu
   bir GÜVENLİK OLAYIDIR (yetkisiz kullanım).
3. **Re-key değerlendirin**: eğer break-glass nedeni "bir custodian'ın
   parçası tehlikeye girdi" ise, `vault-unseal.md` §6.2 adım 4'teki
   `vault operator rekey` prosedürü de ÇALIŞTIRILMALIDIR (root token
   rotasyonu, key rotasyonunun YERİNE GEÇMEZ — ikisi farklı tehditlere
   karşı korur).

---

## 4. Audit log ile çapraz doğrulama

`03-pki.sh`'in `enable_vault_audit()` adımı (Faz 10) her Vault pod'unda
`file` audit device'ını etkinleştirir (`/vault/audit/vault-audit.log`,
per-pod PVC — bkz. `pki/vault/values.yaml` `auditStorage`). Break-glass
sonrası:

```bash
# Her Vault pod'unda ayrı ayrı (paylaşımlı log YOK):
kubectl -n vault exec vault-0 -- tail -n 200 /vault/audit/vault-audit.log \
  | jq -r 'select(.auth.display_name == "root") | "\(.time) \(.request.operation) \(.request.path)"'
```

Bu çıktı, olay kaydındaki adımlarla **satır satır eşleşmelidir**. Eşleşmeyen
bir satır varsa (root token'ın olay kaydı DIŞINDA bir işlem için
kullanıldığı anlamına gelir) derhal ikinci bir olay kaydı açılır ve tüm
custodian'lar bilgilendirilir.

**TEKNİK BORÇ:** audit log'lar şu an yalnızca pod-yerel (paylaşımlı PV
yok) — merkezi bir görünüm (Loki'ye promtail/Vector ile toplama) bu görev
kapsamında YAZILMADI. Bu, `enable_vault_audit()`'in kendi yorumunda da
işaretlendi ve `PLATFORM_CONTEXT.md`'ye teknik borç olarak kaydedilecek.

---

## 5. Planlı (acil olmayan) root token rotasyonu

Break-glass DIŞINDA, aşağıdaki durumlarda da aynı §3.2 prosedürü (onay
şartı OLMADAN, çünkü acil değil — yalnızca platform ekibinin kendi planı)
izlenir:

- Yıllık re-key ile birlikte (aynı bakım penceresinde).
- Bir custodian platformdan ayrıldığında (parçası + potansiyel olarak
  gördüğü herhangi bir root token artık GEÇERSİZ sayılmalı).
- `vault-unseal.md` §7 "Periyodik bakım" tablosundaki program dahilinde.
