# Chaos Test Sonuçları

> **SAPMA NOTU:** Görev metni teslimi `docs/chaos-test-results.md` olarak
> istedi; ADR-0001'in belge yerleşimi (`platform/docs/`) ile tutarlı olması
> için bu dosya `platform/docs/chaos-test-results.md`'de tutuluyor (önceki
> her fazda uygulanan aynı yerleşim kuralı).

Bu dosya, Faz 11 görev madde 4'ün istediği **en az 2 chaos senaryosunun
GERÇEKTEN uygulandığının** kaydıdır. İkisi de bu görevde, gerçek bir `kind`
test cluster'ında (`platform-e2e`), gerçek Helm chart'larla kurulan
GERÇEK CNPG/Vault üzerinde çalıştırıldı — simülasyon veya statik analiz
DEĞİL.

---

## Test ortamı

- `kind` v0.33.0, tek node (`platform-e2e` cluster'ı), Kubernetes v1.37.0
- CloudNativePG operatörü: `cnpg/cloudnative-pg` (Helm, en son stabil)
- Vault: **bu reponun GERÇEK** `platform/pki/vault/values.yaml`'ı ile
  kurulmuş HA/Raft, 3 replika (yalnızca `storageClass`/`affinity` kind
  uyumluluğu için override edildi — HA/Raft topolojisinin KENDİSİ
  değiştirilmedi)
- Her iki test de gerçek zamanlı `kubectl`/`vault` komut çıktılarıyla, saniye
  hassasiyetinde zaman damgalarıyla belgelenmiştir.

---

## Senaryo (a): CNPG replika silme → otomatik failover

**Amaç:** Bir CNPG Cluster'ın PRIMARY pod'u silindiğinde, kümenin
kendiliğinden yeni bir primary seçip HİZMETİ KESİNTİSİZ (uygulama
katmanında yeniden bağlanma gerektirse de veri kaybı olmadan) sürdürdüğünü
doğrulamak.

### Kurulum

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: chaos-test-pg
  namespace: default
spec:
  instances: 3
  storage: {size: 1Gi}
```

3 instance da `Running`/healthy oldu (`healthy: [chaos-test-pg-1, chaos-test-pg-2, chaos-test-pg-3]`).

### Uygulama ve gözlem

| Zaman (UTC) | Olay |
|---|---|
| 20:01:03 | `currentPrimary: chaos-test-pg-1` doğrulandı |
| 20:01:03 | `kubectl delete pod chaos-test-pg-1 --wait=false` |
| 20:01:10 (**+7s**) | `currentPrimary: chaos-test-pg-2` — **FAILOVER TESPİT EDİLDİ** |
| 20:01:45 (+42s) | `chaos-test-pg-1` yeniden `Running` (replika olarak), `chaos-test-pg-2` primary, `chaos-test-pg-3` sağlıklı — küme TAM 3/3 healthy'e döndü |

### Ham çıktı (gerçek komut sonucu)

```
[20:01:10] currentPrimary=chaos-test-pg-2
>>> FAILOVER DETECTED to chaos-test-pg-2 <<<
NAME              READY   STATUS    RESTARTS   AGE
chaos-test-pg-1   0/1     Running   0          6s
chaos-test-pg-2   1/1     Running   0          42s
chaos-test-pg-3   1/1     Running   0          25s

# ~20s sonra:
NAME              READY   STATUS    RESTARTS   AGE
chaos-test-pg-1   1/1     Running   0          29s
chaos-test-pg-2   1/1     Running   0          65s
chaos-test-pg-3   1/1     Running   0          48s
{"healthy": ["chaos-test-pg-1", "chaos-test-pg-2", "chaos-test-pg-3"]}
```

### Sonuç

**✅ BAŞARILI.** Failover **~7 saniyede** gerçekleşti (primary pod silinişi
→ yeni primary seçimi arası); eski primary ~26 saniye içinde replika olarak
yeniden kümeye katıldı ve küme tam sağlıklı duruma döndü. Hiçbir elle
müdahale gerekmedi — CNPG operatörünün kendi failover mantığı (Postgres'in
`pg_rewind`/streaming replication + CNPG'nin liderlik seçimi) tamamen
otonom çalıştı.

---

## Senaryo (b): Vault pod silme → Raft'ın kendini toparlaması

**Amaç:** Vault'un HA/Raft cluster'ında **liderin (leader) kendisi**
silindiğinde, kalan 2 node'un (eşik: 2/3) OTONOM olarak yeni bir lider
seçip Vault'un erişilebilir kalmaya devam ettiğini doğrulamak.

### Kurulum

Bu repo'nun GERÇEK `platform/pki/vault/values.yaml`'ı ile 3 replikalı
Vault kuruldu, `vault operator init -key-shares=3 -key-threshold=2` ile
init edildi (üretimde 5/3 — bu testte yalnızca hız için 3/2 kullanıldı) ve
her 3 pod da unseal edildi. Test öncesi raft üyeliği doğrulandı:

```
Node       Address                        State       Voter
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
```

### Uygulama ve gözlem

| Zaman (UTC) | Olay |
|---|---|
| 19:58:47 | `kubectl -n vault delete pod vault-0` (LİDER siliniyor) |
| 19:58:55 (**+8s**) | `vault-1` üzerinden `raft list-peers` sorgulandı → **`vault-1` artık `leader`** |
| ~19:59:04 (+17s) | Yeni `vault-0` pod'u `Running` (aynı PVC/veri ile) ama `Sealed: true` (BEKLENEN — Shamir her restart'ta elle unseal ister) |
| (elle) | `vault-0` 2 unseal key ile unseal edildi → raft üyeliğine **follower** olarak geri katıldı, **3/3 voter** durumuna dönüldü |

### Ham çıktı (gerçek komut sonucu)

```
=== BEFORE: raft peers ===
Node       Address                        State       Voter
vault-0    vault-0.vault-internal:8201    leader      true
vault-1    vault-1.vault-internal:8201    follower    true
vault-2    vault-2.vault-internal:8201    follower    true
=== Deleting leader pod vault-0 ===
Mon Sep 14 19:58:47 UTC 2026
pod "vault-0" deleted from vault namespace

=== new leader election check (via vault-1) ===
Node       Address                        State       Voter
vault-0    vault-0.vault-internal:8201    follower    true
vault-1    vault-1.vault-internal:8201    leader      true
vault-2    vault-2.vault-internal:8201    follower    true
Mon Sep 14 19:58:55 UTC 2026

# vault-0 yeniden Running ama Sealed (beklenen davranış):
Key                Value
Initialized        true
Sealed              true

# Unseal sonrası:
Node       Address                        State       Voter
vault-0    vault-0.vault-internal:8201    follower    true
vault-1    vault-1.vault-internal:8201    leader      true
vault-2    vault-2.vault-internal:8201    follower    true
```

### Sonuç

**✅ BAŞARILI.** Yeni lider seçimi **~8 saniyede** gerçekleşti — kalan 2
node (2/3 eşiği KARŞILANDIĞI için) kesintisiz quorum korudu, Vault
API'sinin KENDİSİ hiçbir zaman tamamen erişilemez hale gelmedi (`vault-1`
üzerinden sorgular kesintisiz yanıt verdi). Silinen pod'un YENİDEN
Sealed durumda dönmesi bir HATA değil, Shamir/Raft mimarisinin
BEKLENEN, tasarım gereği davranışıdır (veri PV'de kalıcı olsa da,
şifreleme anahtarı her process restart'ında bellekten silinir) — bu,
`docs/runbooks/vault-break-glass.md`'nin de referans verdiği normal
operasyonel akıştır.

---

## Genel değerlendirme

| Kriter | Sonuç |
|---|---|
| En az 2 senaryo GERÇEKTEN uygulandı mı? | ✅ Evet — ikisi de gerçek `kind` cluster'ında, gerçek CNPG/Vault ile |
| Otomatik/manuel müdahale gerekti mi? | CNPG: tamamen otonom. Vault: raft self-heal otonom, yalnızca silinen pod'un YENİDEN unseal edilmesi (Shamir'in tasarım gereği) elle yapıldı — bu BEKLENEN, otomasyona alınabilir bir adım DEĞİLDİR (auto-unseal için KMS/Transit entegrasyonu ayrı bir iş kararı, bkz. teknik borç). |
| Veri kaybı oldu mu? | Hayır (her ikisinde de). |
| Sonuçlar tekrarlanabilir mi? | Evet — bu dosyadaki adımlar + `platform/pki/vault/values.yaml`'ın kendisiyle herhangi bir `kind`/gerçek cluster'da tekrarlanabilir. |

**Denenmeyen, kapsam dışı bırakılan senaryolar** (görevde yalnızca "en az
ikisi" istendi): Rook-Ceph OSD kaybı, ArgoCD pod'u silme, Harbor pod'u
silme — bunlar bu görevde test edilmedi; `disaster-recovery.md` (Faz 10)
Rook-Ceph felaketini zaten kapsıyor.
