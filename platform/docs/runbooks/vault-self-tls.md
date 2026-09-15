> **GÜNCELLEME (Faz 12g, code review #8): bu prosedür artık OTOMATİK.**
> `03-pki.sh`'in `enable_vault_tls()` adımı (§4/7), aşağıdaki adımların
> TAMAMINI sıfırdan bir bootstrap sırasında kendisi çalıştırır — bkz.
> `pki/vault/README.md`'nin "Vault'un kendi TLS'i — ÇÖZÜLDÜ" bölümü. Bu
> runbook, artık YALNIZCA (a) prosedürü ANLAMAK isteyenler için kavramsal
> bir referans, ve (b) TLS'i sonradan ELLE kapatıp AÇMAK (ör. sertifika
> rotasyonunun script DIŞINDA acil elle yapılması gereken bir durumu) için
> tutulur. Normal bootstrap akışında bu adımları ELLE ÇALIŞTIRMANIZ
> GEREKMEZ.
>
> ---

# Runbook: Vault'un Kendi Listener TLS'ini Açma (self-referential PKI)

Açık karar #10 / teknik borç #13'ün ÇÖZÜMÜ. Vault şu an `tls_disable=1` ile
çalışıyor (küme-içi düz metin, yalnızca Cilium NetworkPolicy ile korunuyor).
Bu runbook, Vault'un **kendi sertifikasını kendi PKI'sinden** imzalatıp
listener'ı TLS'e geçirme prosedürünü tanımlar.

**KARAR (bu görevde verildi):** Bu işlem OTOMATİK bootstrap akışına
BAĞLANMADI — `03-pki.sh`'in normal çalışması hâlâ `tls_disable=1` ile
devam eder. Gerekçe: bu değişiklik Vault'un 3 pod'unu da SIRAYLA yeniden
başlatmayı (`helm upgrade` → rolling restart → HER pod'un tekrar unseal
edilmesini) gerektirir — bir bootstrap script'inin ORTASINDA bunu otomatik
yapmak, bir hata durumunda Vault'u ERİŞİLEMEZ bırakma riski taşır (tam da
önceki fazın "aciliyet yok" kararının gerekçesi). Bu yüzden bu runbook,
Vault sağlıklı çalıştıktan UZUN SÜRE SONRA, bir bakım penceresinde,
**operatörün elle** tetiklediği AYRI bir prosedürdür.

## 1. Ön koşul

Vault unsealed, `pki-int-<env>` mount'u var, `VAULT_TOKEN` export edilmiş
(bkz. `vault-unseal.md` §3.3).

## 2. Vault'un kendi PKI rolünü oluştur

```bash
vault write pki-int-${ENVIRONMENT}/roles/vault-server \
  allowed_domains="vault-internal,vault.vault.svc.cluster.local,vault-active.vault.svc.cluster.local" \
  allow_subdomains=true \
  allow_bare_domains=true \
  max_ttl="2160h" \
  key_type=rsa key_bits=2048
```

## 3. Her Vault pod'u için bir sertifika üret

```bash
for i in 0 1 2; do
  vault write -format=json pki-int-${ENVIRONMENT}/issue/vault-server \
    common_name="vault-${i}.vault-internal" \
    alt_names="vault.vault.svc.cluster.local,vault-active.vault.svc.cluster.local" \
    ttl="2160h" > /tmp/vault-${i}-cert.json
  jq -r '.data.certificate + "\n" + .data.issuing_ca' /tmp/vault-${i}-cert.json > /tmp/vault-${i}.crt
  jq -r '.data.private_key' /tmp/vault-${i}-cert.json > /tmp/vault-${i}.key
  kubectl -n vault create secret tls "vault-${i}-server-tls" \
    --cert="/tmp/vault-${i}.crt" --key="/tmp/vault-${i}.key" \
    --dry-run=client -o yaml | kubectl apply -f -
  shred -u "/tmp/vault-${i}.key" 2>/dev/null || rm -f "/tmp/vault-${i}.key"
done
```

## 4. Helm values güncellemesi (`pki/vault/values.yaml`)

```yaml
server:
  volumes:
    - name: vault-tls-0
      secret: {secretName: vault-0-server-tls}
    # ... vault-1, vault-2 için aynı deseni tekrarlayın; StatefulSet'in her
    # pod'u için AYRI bir secret gerekir (pod-özel CN) — chart'ın
    # `server.volumes`/`extraVolumes` mekanizması pod-index'e göre koşullu
    # mount YAPAMAZ, bu yüzden pratikte HER 3 secret de HER pod'a
    # (initContainer'da doğru olanı seçen küçük bir script ile) ya da tek
    # bir wildcard-benzeri SAN'lı TEK sertifikayla (3 pod'un TAMAMI için
    # geçerli tek bir cert, `alt_names` içinde vault-0/1/2 hepsi) çözülür.
    # BASİTLİK İÇİN İKİNCİ YOL ÖNERİLİR — bkz. adım 3'ün alt_names'ine
    # vault-0/1/2'nin HEPSİNİ eklemek.
  volumeMounts:
    - name: vault-tls-0
      mountPath: /vault/userconfig/vault-server-tls
      readOnly: true
  ha:
    raft:
      config: |
        ui = true
        listener "tcp" {
          address         = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_disable     = false
          tls_cert_file   = "/vault/userconfig/vault-server-tls/tls.crt"
          tls_key_file    = "/vault/userconfig/vault-server-tls/tls.key"
        }
        storage "raft" {
          path = "/vault/data"
          retry_join { leader_api_addr = "https://vault-0.vault-internal:8200" }
          retry_join { leader_api_addr = "https://vault-1.vault-internal:8200" }
          retry_join { leader_api_addr = "https://vault-2.vault-internal:8200" }
        }
        service_registration "kubernetes" {}
```

**Basitleştirilmiş öneri:** adım 3'te TEK bir sertifika üretin
(`common_name=vault-active.vault.svc.cluster.local` — rolün allowed_domains'inde TAM eşleşen giriş, bkz. DÜZELTME notu; `alt_names` içinde `vault-0.vault-internal,
vault-1.vault-internal,vault-2.vault-internal,vault.vault.svc.cluster.local,
vault-active.vault.svc.cluster.local`), TEK bir `vault-server-tls` Secret'ı
oluşturun, TÜM pod'lara AYNI Secret'ı mount edin — pod-başına ayrı
sertifika YÖNETİM KARMAŞIKLIĞINI ortadan kaldırır (üç sertifikanın ayrı ayrı
rotasyonu yerine tek bir sertifika).

## 5. Uygula ve doğrula

```bash
helm upgrade vault hashicorp/vault -n vault -f platform/pki/vault/values.yaml --wait --timeout 10m
# Her pod restart sonrası YENİDEN unseal edilmelidir (bkz. vault-unseal.md §4):
for pod in vault-0 vault-1 vault-2; do
  vault operator unseal ... # (kubectl exec ile, 2 anahtar)
done
kubectl -n vault exec vault-0 -- vault status
# "HTTPS" ile erişilebilir olduğunu doğrulayın:
kubectl -n vault exec vault-0 -- sh -c "VAULT_ADDR=https://127.0.0.1:8200 VAULT_SKIP_VERIFY=true vault status"
```

## 6. Geri alma

`tls_disable=1`'e dönmek için values.yaml'ı ESKİ hâline getirip `helm
upgrade` çalıştırın — pod'lar yeniden başlar, yine unseal gerekir. Sertifika
Secret'ları silinmez, sonraki bir denemede yeniden kullanılabilir.

## 7. Bu görevde yapılan/yapılmayan

- ✅ Prosedürün TAMAMI (rol oluşturma, sertifika üretimi, Helm values
  değişikliği, doğrulama, geri alma) yazıldı ve mevcut mimariyle (pki-int
  mount'ları, `vault-internal` headless Service, chart'ın `server.volumes`
  mekanizması) tutarlı olacak şekilde tasarlandı.
- ❌ **GERÇEK bir Vault cluster'ında UYGULANMADI** — bu, mevcut, çalışan bir
  Vault HA cluster'ının 3 pod'unu SIRAYLA yeniden başlatmayı gerektirir;
  bilinçli olarak "aciliyeti olmayan, elle tetiklenen bakım penceresi
  işlemi" olarak bırakıldı (yukarıdaki KARAR notuna bakın) — otomatik
  bootstrap akışına EKLENMEMESİ kasıtlıdır, atlanmış bir adım DEĞİLDİR.
