# Runbook: Vault Init / Unseal / Break-Glass

| Alan | Değer |
|---|---|
| Kapsam | `platform/pki/vault/` — HA Raft, 3 replika, Shamir (5 parça / eşik 3) |
| Sıklık | Init: yalnızca kurulumda (bir kez). Unseal: her Vault pod restart'ında. Re-key: yılda 1 + personel değişikliğinde. |
| Ön koşul | `03-pki.sh --only vault` çalıştırılmış, 3 pod da `Running` (henüz `Ready` DEĞİL — sealed) |

> **KURAL (tekrar tekrar):** Bu runbook'un HİÇBİR adımı, üretilen unseal
> key'lerini veya root token'ı bir dosyaya/repoya/chat mesajına yapıştırmayı
> içermez. Her komutun çıktısı yalnızca **terminalde görünür**, ilgili
> custodian tarafından **kendi güvenli saklama aracına** (parola yöneticisi,
> donanım güvenli kasa, kağıt zarf + fiziksel kasa) elle aktarılır.

---

## 1. Kavramlar

- **Shamir Secret Sharing:** Vault'un kök şifreleme anahtarı (master key) 5
  parçaya bölünür (`-key-shares=5`). Vault'u mühürsüzlemek (unseal) için
  bunlardan **herhangi 3'ü** yeterlidir (`-key-threshold=3`). Tek bir kişi
  Vault'u asla tek başına açamaz.
- **Root token:** `vault operator init` çıktısının bir parçası, sınırsız
  yetkili tek kullanımlık bir kimlik bilgisidir. Yalnızca ilk bootstrap
  (auth method'lar, policy'ler, PKI mount'ları) için kullanılır, sonra
  **iptal edilir** (bkz. §5).
- **Unseal**, Vault'u AÇMAK demektir (init sonrası veya her pod restart'ında);
  **init** yalnızca BİR KEZ, kümenin ömründe bir defa yapılır.

---

## 2. Key custodian şeması (5 parça / eşik 3)

Aşağıdaki roller **örnektir** — gerçek isimlerle değiştirin ve
`docs/PLATFORM_CONTEXT.md` §3'e (açık kararlar) hangi kişinin hangi rolü
üstlendiğini (isim değil, ROL yazarak) kaydedin.

| Parça # | Custodian rolü | Saklama yeri (önerilen) |
|---|---|---|
| 1 | Platform Ekibi Lideri | Kişisel donanım güvenlik anahtarı + parola yöneticisi (örn. 1Password kasası, yalnızca kendisi) |
| 2 | Güvenlik Sorumlusu (Security Officer) | Kurumsal parola yöneticisinin "Security" kasası |
| 3 | Nöbetçi SRE Lideri (rotasyonlu) | Nöbet devrinde EL DEĞİŞTİRİR — devir sırasında yeniden yazdırılıp eskisi imha edilir |
| 4 | Mühendislik Müdürü | Kişisel güvenli saklama |
| 5 | **Offsite / Break-glass** | Fiziksel kasa (ofis dışı, örn. banka kasası) — yalnızca §6'daki break-glass prosedüründe açılır |

**Kural:** Aynı kişi 2'den fazla parçayı **tutamaz** (3 parça = tek kişi
Vault'u açabilir demektir, Shamir'in amacını boşa çıkarır).

---

## 3. Init (yalnızca BİR KEZ)

### 3.1 Ön kontrol

```bash
kubectl -n vault get pods
# Beklenen: vault-0, vault-1, vault-2 → Running (1/1 DEĞİL, readinessProbe
# henüz sealed olduğu için fail veriyor — bu NORMAL, "Ready" sütunu 0/1 kalır)

kubectl -n vault exec vault-0 -- vault status
# Beklenen çıktı: "Initialized: false", "Sealed: true"
```

Eğer `Initialized: true` görüyorsanız — **BU RUNBOOK'UN 3. BÖLÜMÜNÜ ATLAYIN**,
doğrudan §4 (unseal) veya §6 (break-glass) bölümüne gidin. Zaten init edilmiş
bir Vault'u tekrar init etmeye ÇALIŞMAYIN (veri kaybı riski yoktur ama
komut reddedilir ve yeni bir key seti üretmez — eski key'ler geçersiz olur
diye YANLIŞ anlaşılabilir; init edilmiş bir Vault'ta init komutu basitçe hata verir).

### 3.2 Init komutu — 5 parça, eşik 3

```bash
kubectl -n vault exec -it vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > /tmp/vault-init-DO-NOT-COMMIT.json
```

> **`/tmp/...` bilinçli.** Bu dosya **repo dizini DIŞINDA**, geçici bir
> konumda oluşturulur. `platform/` altında hiçbir yerde init çıktısı
> tutulmaz — `.gitignore` bunu yakalayacak bir yapı bile eklemiyoruz çünkü
> **böyle bir dosyanın var olması gerektiği hiçbir senaryo yoktur.**

### 3.3 Parçaları HEMEN dağıtın, dosyayı HEMEN silin

```bash
python3 -c "
import json
d = json.load(open('/tmp/vault-init-DO-NOT-COMMIT.json'))
for i, k in enumerate(d['unseal_keys_b64'], 1):
    print(f'--- Unseal Key {i} (custodian #{i}\\'e ver) ---')
    print(k)
print('--- Root Token (yalnızca §5 bootstrap için, sonra iptal) ---')
print(d['root_token'])
"
```

Her satırı **terminalden okuyup ilgili custodian'a sözlü/güvenli kanaldan**
iletin (ekran görüntüsü almayın, Slack/e-posta ile GÖNDERMEYİN). İletim
bitince:

```bash
shred -u /tmp/vault-init-DO-NOT-COMMIT.json 2>/dev/null || rm -P /tmp/vault-init-DO-NOT-COMMIT.json
# macOS'ta 'shred' yoksa: rm -P (3 kez overwrite) veya `srm` (varsa) kullanın.
```

Root token'ı **yalnızca §5'teki bootstrap adımları için** geçici olarak bir
ortam değişkeninde tutun (dosyaya YAZMAYIN):

```bash
export VAULT_TOKEN="<root token — yalnızca bu terminal oturumunda, elle girilir>"
```

---

## 4. Unseal (her pod restart'ında tekrarlanır)

Her Vault pod'u **ayrı ayrı** ve **birbirinden bağımsız olarak** mühürsüzlenir
(Raft, her node'un kendi disk şifrelemesini kendi açmasını gerektirir).
3 farklı custodian, kendi parçalarını **art arda aynı pod'a** girer:

```bash
for pod in vault-0 vault-1 vault-2; do
  echo "=== $pod ==="
  kubectl -n vault exec -it "$pod" -- vault operator unseal   # Custodian #1 parçasını girer
  kubectl -n vault exec -it "$pod" -- vault operator unseal   # Custodian #2 parçasını girer
  kubectl -n vault exec -it "$pod" -- vault operator unseal   # Custodian #3 parçasını girer
  kubectl -n vault exec "$pod" -- vault status | grep Sealed
  # Beklenen: "Sealed: false"
done
```

> **ÖNEMLİ:** Yukarıdaki döngü OTOMATİKLEŞTİRİLEMEZ (kasıtlı olarak
> `03-pki.sh` içine konmadı) — her `vault operator unseal` çağrısı bir
> İNSANIN kendi parçasını elle girmesini gerektirir. Script bu adımı
> **beklemeye alır** (`wait_for` ile "Sealed: false" durumunu kontrol eder,
> hiçbir parçayı kendisi girmez).

### Doğrulama

```bash
kubectl -n vault get pods
# vault-0/1/2 → 1/1 Running (Ready)

kubectl -n vault exec vault-0 -- vault status
# Sealed: false, HA Mode: active veya standby
```

---

## 5. İlk bootstrap sonrası: root token'ı iptal edin

Root token, `03-pki.sh`'in auth method/PKI/policy kurulum adımlarında
**bir kez** kullanılır. Bu adımlar bitince:

```bash
# 1. Root token yerine kullanılacak, sınırlı yetkili bir admin policy/token
#    üretin (günlük operasyon için root token KULLANILMAZ):
vault policy write platform-admin - <<'EOF'
path "*" { capabilities = ["read", "list"] }
path "pki-int-*/roles/*" { capabilities = ["read", "list"] }
path "auth/kubernetes/role/*" { capabilities = ["read", "list", "create", "update"] }
EOF

# 2. İlk root token'ı iptal edin:
vault token revoke -self

# 3. Gerekirse yeni bir root token yalnızca break-glass'ta (§6) üretilir.
```

---

## 6. Break-glass prosedürü

**Ne zaman kullanılır:** (a) 2+ custodian aynı anda ulaşılamaz durumda ve
acil bir unseal/re-key gerekiyor, (b) root token kaybedildi/tehlikeye girdi
ve yeni bir tane üretilmesi gerekiyor, (c) bir custodian ayrılıyor ve
re-key şart.

### 6.1 Aktivasyon şartı

Break-glass, **en az iki** kişinin (örn. Platform Ekibi Lideri + Güvenlik
Sorumlusu) ortak onayı OLMADAN başlatılamaz. Tek kişi kararıyla offsite
kasa (parça #5) açılmaz.

### 6.2 Adımlar

```bash
# 1. Onay: iki yetkili, olay kaydı (incident ticket) açar ve break-glass
#    gerekçesini yazar.

# 2. Offsite kasadan parça #5 çıkarılır (fiziksel erişim + kasa kaydı).

# 3. Mevcut/ulaşılabilen custodian'lardan (parça #5 + herhangi 2 diğeri = 3)
#    normal unseal prosedürü (§4) uygulanır.

# 4. Acil durum sonrası: KEY RE-KEY (yeni bir 5/3 set üretimi) ZORUNLUDUR —
#    kullanılan eski key set'i artık "yakılmış" sayılır:
vault operator rekey -init -key-shares=5 -key-threshold=3
# Çıktıyı yeni custodian'lara TEKRAR §2'deki şemayla dağıtın; eski parçaları
# imha edin (custodian'lar kendi saklama alanlarını temizler).

# 5. Offsite kasaya YENİ parça #5 konur, olay kaydı kapatılır.
```

### 6.3 Root token kaybı / tehlikeye girmesi

**Faz 10'da AYRI bir dosyaya taşındı:** bu senaryonun tam prosedürü
(aktivasyon şartı, adım adım komutlar, audit log çapraz doğrulaması,
planlı rotasyon) artık [`vault-break-glass.md`](vault-break-glass.md)'de —
TEK doğruluk kaynağı odur, burada tekrar EDİLMEZ.

---

## 7. Periyodik bakım

| Ne | Sıklık | Komut |
|---|---|---|
| Re-key (yeni Shamir seti) | Yılda 1 + personel değişikliğinde | `vault operator rekey -init ...` (bkz. §6.2 adım 4) |
| Root token rotasyonu | Her bootstrap sonrası hemen | `vault token revoke -self` (§5) |
| Unseal key custodian listesi gözden geçirme | Her çeyrek | Bu dosyanın §2 tablosu güncellenir |
| Raft snapshot (yedek) | Günlük (Faz 9: Velero entegrasyonu) | `vault operator raft snapshot save /tmp/raft.snap` (yerel disk DIŞINA taşınmalı) |

---

## 8. Sık karşılaşılan hatalar

| Belirti | Neden | Çözüm |
|---|---|---|
| `Error: context deadline exceeded` unseal sırasında | Yanlış pod'a (leader olmayan) yazılıyor olabilir | Her 3 pod'u AYRI AYRI unseal edin (§4) — hepsi kendi diskini açmalı |
| Init sonrası pod'lar hâlâ `0/1` | Yalnızca `vault-0` unseal edildi | §4'teki döngüyü `vault-1` ve `vault-2` için de çalıştırın |
| `permission denied` PKI mount ederken | Root token iptal edilmiş, sınırlı token kullanılıyor | Yeni bir root token gerekiyorsa §6.3 |
| 2 node aynı anda kaybedildi, quorum yok | Raft 3 node'da 2 kayıpta yazma durur (kasıtlı, bkz. Rook-Ceph README'deki aynı ilke) | 3. node'u kurtarın veya yeni bir node ekleyip `vault operator raft join` |
