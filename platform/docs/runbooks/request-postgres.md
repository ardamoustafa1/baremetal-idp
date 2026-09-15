# Runbook: Postgres Nasıl İstenir

| Alan | Değer |
|---|---|
| Kime hitap ediyor | Geliştirici / tenant sahibi |
| Ön koşul | Tenant'ınız zaten var olmalı (`kubectl get xtenant` ile görün) |
| Süre | Genellikle **birkaç dakika** (öngörülemez uzatan faktörler aşağıda) |
| İlgili composition | [`platform/compositions/postgresql/`](../../compositions/postgresql/) |

---

## 1. Claim'i yazın

`tenant-requests` reposunda (veya bu repoda `examples/` altındaki
örneklere bakarak) bir `PostgreSQLInstance` claim'i açın:

```yaml
apiVersion: platform.internal/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: orders-db              # Postgres cluster'ınızın adı — Service'ler
                                # bu adı temel alır (örn. orders-db-rw)
  namespace: tenant-requests
spec:
  size: medium                 # small | medium | large — bkz. §2
  version: "16"                 # "14" | "15" | "16" | "17"
  highAvailability: true       # bkz. §3 — size ile UYUMLU olmalı
  tenantRef: tenant-acme-dev   # KENDİ tenant namespace'iniz — bkz. §4
```

## 2. `size` — hangisini seçmeliyim?

| `size` | Replika | CPU | Bellek | Disk | Ne zaman |
|---|---|---|---|---|---|
| `small` | 1 | 2 | 4Gi | 20Gi | Dev/test, tek seferlik iş, kritik olmayan |
| `medium` | 2 | 4 | 8Gi | 100Gi | Tipik üretim servisi |
| `large` | 3 | 8 | 16Gi | 500Gi | Yüksek hacimli/kritik veri |

Ara değer yoktur — `conventions.md` §4.3'teki t-shirt tier felsefesiyle
aynı gerekçe: kapasite planlaması ve maliyet öngörülebilirliği.

## 3. `highAvailability` — ÖNEMLİ KISIT

```
highAvailability: true  +  size: small   →  REDDEDİLİR
```

**Neden:** `small`, 1 replika üretir; HA en az 2 replika ister. Bu kural
**iki yerde** zorlanır — XRD'nin admission-zamanı doğrulaması (anında red)
ve composition'ın KCL fonksiyonu (`function.k`, ikinci bariyer). Reddedilme
mesajı şuna benzer:

```
highAvailability=true icin minimum 2 replika gerekir (size=small -> 1 replika).
size=medium veya size=large secin.
```

**Çözüm:** `size: medium` veya `size: large` seçin, ya da `highAvailability: false`
bırakın.

## 4. `tenantRef` — hangi değeri yazmalıyım?

`tenantRef`, **kendi Tenant'ınızın namespace adıdır** — bir Tenant claim
adı DEĞİL. Kendi namespace'inizi öğrenmek için:

```bash
kubectl get xtenant   # sizin tenant'ınızın namespace'i status'te görünür
# veya doğrudan:
kubectl get ns -l platform.internal/tenant=<takım-adınız>
```

Örnek: `acme` takımının `dev` ortamındaki tenant'ı için
`tenantRef: tenant-acme-dev`.

## 5. Ne zaman hazır olur?

```bash
kubectl get postgresqlinstance orders-db -n tenant-requests
kubectl get cluster orders-db -n tenant-acme-dev   # CNPG'nin kendi CR'ı
```

| Aşama | Süre (tipik) | Ne oluyor |
|---|---|---|
| Claim → XR dönüşümü | saniyeler | Crossplane composition'ı çalıştırır |
| Yedekleme bucket'ı (Rook OBC) | saniyeler-1 dk | Rook, S3 bucket + kimlik bilgisi üretir |
| TLS sertifikası | saniyeler | Vault, tenant'ın kendi PKI rolünden imzalar |
| **CNPG Cluster ilk ayağa kalkış** | **2-5 dakika** | PostgreSQL init, replikasyon kurulumu (`highAvailability`) |
| Bağlantı sırrının Vault round-trip'i | 1-2 dakika | CNPG secret → PushSecret → Vault → ExternalSecret |

**Toplam: genellikle 5 dakikanın altında.** Daha uzun sürüyorsa §7'ye bakın.

## 6. Bağlantı bilgisine nereden ulaşırım?

```bash
kubectl get secret orders-db-connection -n tenant-acme-dev -o yaml
```

Bu Secret şu anahtarları içerir: `host`, `port`, `username`, `password`,
`dbname`. Uygulamanızda bunu bir `envFrom.secretRef` veya
`valueFrom.secretKeyRef` ile tüketin — **elle kopyalamayın**, Secret
CNPG'nin kendi parola rotasyonuyla güncellenir ve ExternalSecret bunu
otomatik yansıtır (saatlik `refreshInterval`).

> **Neden `<name>-connection`, `<name>-app` değil?** CNPG kendi
> `<name>-app` Secret'ını zaten üretir (aynı namespace'te, doğrudan
> kullanılabilir) — `<name>-connection`, bunun Vault üzerinden geçmiş
> (push+pull) kopyasıdır. Platform standardı gereği (ADR-0001 Karar 2.3:
> tüm secret'lar tek bir mekanizmadan — Vault'tan — akar) uygulamanızın
> `<name>-connection`'ı kullanması ÖNERİLİR.

## 7. Bağlantı TLS ile mi?

Evet — CNPG, tenant'ınızın kendi cert-manager Issuer'ından (`tenant-issuer`)
alınan bir sertifikayla TLS'i **zorunlu** kılar. İstemci kütüphaneniz
`sslmode=verify-full` (veya eşdeğeri) kullanmalı; CA sertifikası aynı
Secret'ın (`<name>-server-tls`) `ca.crt` alanındadır.

## 8. Yedekleme ve geri yükleme (PITR)

| `size` | Günlük yedek | PITR saklama |
|---|---|---|
| `small` | ✅ 02:00 UTC | 7 gün |
| `medium` | ✅ 02:00 UTC | 14 gün |
| `large` | ✅ 02:00 UTC | 30 gün |

Yedekler Rook-Ceph RGW'ye (S3 uyumlu) Barman ile yazılır. Nokta-zaman
kurtarma (Point-In-Time Recovery) CNPG'nin kendi mekanizmasıyla yapılır —
ayrı bir runbook'ta (Faz 9, felaket kurtarma tatbikatı) ele alınacak.

## 9. Sık karşılaşılan sorunlar

| Belirti | Olası neden | Kontrol |
|---|---|---|
| Claim reddedildi, "highAvailability=true icin minimum 2 replika" | §3'teki kısıt | `size`'ı `medium`/`large` yapın |
| Claim reddedildi, "tenantRef" pattern hatası | `tenantRef` gerçek bir tenant namespace'i değil | §4'teki komutla doğru adı bulun |
| Cluster saatlerce `Ready` olmuyor | Node'da yeterli `ceph-block` kapasitesi yok, ya da PVC `Pending` | `kubectl get pvc -n <tenantRef>` |
| `<name>-connection` Secret'ı görünmüyor | Vault/ESO henüz kurulmamış (Faz 3/7 tamamlanmadıysa) | `kubectl get secretstore,pushsecret,externalsecret -n <tenantRef>` |
| TLS handshake hatası | Sertifika henüz imzalanmadı (Vault unseal edilmemiş olabilir) | `kubectl get certificate <name>-server-tls -n <tenantRef>` |
| Başka bir tenant'tan bağlanamıyorum | **BEKLENEN** — cross-tenant erişim CiliumNetworkPolicy ile engellidir | Bu bir hata değil, izolasyon böyle tasarlandı |
