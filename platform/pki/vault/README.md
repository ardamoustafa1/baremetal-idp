# Vault — HA / Raft, PKI, Kubernetes Auth

ADR-0001 Karar 2.3. Kurulum: [`platform/bootstrap/03-pki.sh`](../../bootstrap/03-pki.sh).
Init/unseal: [`docs/runbooks/vault-unseal.md`](../../docs/runbooks/vault-unseal.md).

---

## Root CA izolasyonu — dürüst bir not

Görev, Root CA'nın **ayrı bir "root" Vault namespace'inde** tutulmasını
istiyor. **Vault Namespaces, HashiCorp Vault ENTERPRISE'ın lisanslı bir
özelliğidir** — bu platform açık kaynak (OSS) Vault kullanıyor (ADR-0001'de
Enterprise lisansı hiç gündeme gelmedi ve maliyeti kabul edilmedi). Bu
yüzden **gerçek Vault Namespace kullanılmıyor.**

Bunun yerine, OSS içinde ulaşılabilen en yakın karşılığı uyguladık:

| Enterprise'da olsaydı | OSS'de yaptığımız |
|---|---|
| Ayrı `root` namespace, ayrı RBAC sınırı | Ayrı bir **mount path** (`pki-root`, diğerlerinden (`pki-int-*`) tamamen ayrı) |
| Namespace bazlı erişim izolasyonu | **Ayrı bir Vault policy** (`root-ca-admin-policy.hcl`) — hiçbir günlük operasyon rolüne (cert-manager, crossplane) atanmaz |
| Kalıcı olarak erişilemez root | **Break-glass prosedürü** (docs/runbooks/vault-unseal.md §6) — `root-ca-admin` policy'si normal zamanda KİMSEYE bağlı değil |

**Gerçek offline root** (Vault'un kendisinin bile hiç bilmediği bir kök)
istenirse, tek yol Root CA'yı **tamamen ayrı, fiziksel/mantıksal olarak
izole bir Vault instance'ında** (veya tamamen offline bir OpenSSL kök CA'da)
tutup yalnızca ara sıra devreye alıp Intermediate CSR'larını imzalatmaktır.
Bu, mevcut 3-node bare-metal kapsamının önemli ölçüde ötesinde bir operasyonel
yük getirir (ayrı bir cluster/host, ayrı bir unseal prosedürü, ayrı bir
network yolu) — **bu fazda bilinçli olarak yapılmadı.** İleride gerekirse
`pki-root` mount'u buraya taşınabilir; hiçbir tüketici (cert-manager,
compositions) bunun farkına varmaz çünkü onlar yalnızca `pki-int-*`
mount'larını bilir.

---

## Neden Raft (integrated storage), Consul/etcd değil

- **Ek bir bağımlılık yok.** Consul veya harici bir depolama backend'i,
  işletilecek BAŞKA bir dağıtık sistem demektir. Raft, Vault'un KENDİ
  process'i içinde çalışır.
- **Rook-Ceph zaten var.** Raft'ın PV ihtiyacı (`ceph-block`, `ReadWriteOnce`)
  Faz 1'in ürettiği StorageClass ile karşılanıyor — yeni bir depolama
  sistemi gerekmiyor.
- 3 node → 3 Raft peer → quorum: 2/3. Bir node kaybında Vault **yazılabilir**
  kalır (Rook-Ceph'in 3/2 replikasyon ilkesiyle birebir aynı mantık).

---

## Vault'un kendi TLS'i — ÇÖZÜLDÜ (Faz 12g, code review #8)

`values.yaml` (bu dosya) hâlâ **BİRİNCİ AŞAMA**'yı tanımlar —
`global.tlsDisable: true`, listener `tls_disable = 1` — çünkü Vault'un
kendi sunucu sertifikasını kendi PKI'sinden (`pki-int-dev`) imzalatabilmesi
için önce AYAKTA ve unsealed olması gerekir (self-referential bootstrap,
klasik tavuk-yumurta problemi). Bu artık kabul edilmiş bir SINIR değil,
**İKİ AŞAMALI bir bootstrap sırasının BİRİNCİ adımı**:

1. **Bu dosyayla** ilk `helm install` (plaintext, yalnızca küme-içi +
   Cilium NetworkPolicy ile korunur).
2. `03-pki.sh`'in `enable_vault_tls()` adımı — PKI hiyerarşisi kurulduktan
   HEMEN sonra, cert-manager'dan ÖNCE — `pki-int-dev/roles/vault-server`
   rolünü tanımlar, TEK bir sertifika (tüm `vault-0/1/2` + Service SAN'larını
   kapsayan) imzalatır, `vault/vault-server-tls` Secret'ını oluşturur ve
   `values.yaml` + **`values-tls.yaml`** (İKİNCİ AŞAMA overlay'i) ile
   `helm upgrade` çalıştırarak listener'ı GERÇEKTEN HTTPS'e geçirir. Her
   pod, restart sonrası transit auto-unseal (Faz 12e) ile OTOMATİK unseal
   olur — script bunu doğrular.

Bu prosedür, bu dizindeki eski `docs/runbooks/vault-self-tls.md`
runbook'unun (elle, bakım penceresinde tetiklenen versiyon) OTOMATİKLEŞTİRİLMİŞ
hâlidir — SIFIRDAN bir bootstrap'ın PARÇASI olarak (henüz hiçbir tenant
verisi yokken) çalıştığı için, runbook'un "canlı bir cluster'ı riske atma"
endişesi burada GEÇERLİ DEĞİL.

Sonuç olarak cert-manager'ın `ClusterIssuer`/`Issuer` kaynakları, ESO'nun
`SecretStore`'ları ve tenant bootstrap Job'unun kendi `vault` CLI çağrıları
artık HEPSİ `https://vault-active.vault.svc.cluster.local:8200` kullanıyor
— bkz. `pki/cert-manager/resources/clusterissuers.yaml.tpl` (`caBundle`),
`compositions/postgresql/function.k` §7 ve `compositions/tenant/function.k`
(`vaultCaSecretStore`/`vaultCaExternalSecret`, `caProvider`/
`caBundleSecretRef`), `backstage/app/resources/secretstore-externalsecret.yaml`.

**KAPSAM DIŞI (bilinçli):** `vault-unseal/` (Transit auto-unseal için
kullanılan ikincil, küçük Vault örneği) bu kapsamda DEĞİL — yalnızca ana
Vault'a bağlanan bileşenler kapsandı.

### Sertifika yenileme (Faz 12j, code review #7'nin çözümü)

`vault-server-tls` sertifikası 90 gün (`ttl=2160h`) geçerlidir ve HERHANGİ
bir otomatik yenileme mekanizmasına (cert-manager Certificate/Job/CronJob)
BAĞLI DEĞİLDİR — bu, Vault'un kendi listener sertifikasının Vault'un
KENDİ PKI'sinden geldiği self-referential yapı gereği bilinçli bir tasarım
(cert-manager'ın Vault Issuer'ları ZATEN Vault'un kendisine bağımlı, Vault'un
KENDİ sertifikasını cert-manager'a yaptırmak dairesel bir bağımlılık
olurdu). Yenileme YERİNE `enable_vault_tls()` **idempotent ve tekrar
çalıştırılabilir** hâle getirildi: her çalıştırmada sertifika YENİDEN
ÜRETİLİR ve pod'lar sırayla yeniden başlatılır (transit auto-unseal
sayesinde insan müdahalesi gerekmez). Operatör süresi dolmadan (**90
günden ÖNCE, ör. her 60 günde bir**) şunu çalıştırmalıdır:

```bash
export VAULT_TOKEN="<root veya yeterli yetkili bir token>"
./platform/bootstrap/03-pki.sh --only vault-tls
```

Vault listener sertifikası `observability/resources/vault-tls-monitor.yaml`
ile her dakika gerçek HTTPS bağlantısı üzerinden izlenir. Blackbox exporter
`vault-ca-bundle` CA’sıyla zincir ve isim kontrolü yapar. Prometheus kuralları
30 gün, 7 gün, başarısız bağlantı ve kayıp izleme sinyali için alarm üretir.
Kaynaklar 05-observability bootstrap’ı ve observability Argo uygulamasına bağlıdır.
Alertmanager alıcısına gerçek teslimat canlı kabulde doğrulanmalıdır.

Yenileme operatör kontrollüdür; root token tutan otomatik bir CronJob kurulmaz.
Sertifika yenileme komutu standby’ları önce, lideri en son yeniden başlatır.
Kontroller loopback bağlantısında `VAULT_TLS_SERVER_NAME` ile sertifikadaki
ismi doğrular. CA kalıcı ConfigMap mount’undan okunur; yeni Raft üyeleri de
`leader_ca_cert_file` ile aynı CA’ya güvenir.

```bash
./platform/bootstrap/03-pki.sh --verify-only --only vault-tls
```

**DÜZELTME (Faz 12l, code review #1):** `enable_vault_tls()` artık pod'ları
GERÇEKTEN sırayla (standby önce, active en son) SİLİP yeniden oluşturuyor
ve HER pod'un mounted sertifikasının SHA-256'sını yerel dosyayla
KARŞILAŞTIRARAK doğruluyor — chart'ın `server.updateStrategyType`
varsayılanı `OnDelete` olduğu için (Helm render'ıyla doğrulandı), daha
önceki `kubectl rollout restart` çağrısı bir NO-OP'tu ve pod'lar SESSİZCE
eski konfigürasyonda kalmaya devam ederdi.

**ESO/cert-manager login testi (üretimde, her yenileme SONRASI ÖNERİLİR,
bu görevde ÇALIŞTIRILAMADI):**

```bash
# Vault pod'u yeniden başladıktan SONRA, ESO'nun/cert-manager'ın YENİ
# sertifikayla auth olabildiğini doğrulayın — yalnızca "Vault HTTPS
# dinliyor" YETERLİ DEĞİLDİR, istemcilerin GERÇEKTEN login olabildiğini
# kanıtlamak gerekir:
kubectl -n tenant-acme-dev delete externalsecret vault-ca-bundle --wait=false 2>/dev/null || true
kubectl -n tenant-acme-dev annotate issuer tenant-issuer force-resync="$(date +%s)" --overwrite
kubectl -n tenant-acme-dev wait issuer/tenant-issuer --for=condition=Ready --timeout=60s
```

---

### Kubernetes auth — `token_reviewer_jwt` rotasyonu (Faz 12l, code review #2)

`auth/kubernetes/config` yazılırken `token_reviewer_jwt` BİLİNÇLİ OLARAK
BOŞ bırakılır — `=@dosya` sözdizimi dosyanın İÇERİĞİNİ o ANDA okuyup SABİT
bir string olarak Vault'a yazar, ama Vault'un KENDİ ServiceAccount
token'ı (projected, TTL'li) kubelet tarafından periyodik olarak
ROTATE edilir. Alan boş bırakılınca Vault, TokenReview çağrıları için
KENDİ token dosyasını HER İSTEKTE CANLI okur — rotasyonu otomatik takip
eder. `tests/e2e/kind-chain/run.sh` bu deseni ZATEN kullanıyordu (bkz.
resmi Vault dokümantasyonu: https://developer.hashicorp.com/vault/docs/auth/kubernetes).

---

## Doğrulama

```bash
kubectl -n vault get pods                    # 3/3 Running
kubectl -n vault exec vault-0 -- vault status   # Sealed: false
kubectl get secretengines 2>/dev/null || true
./platform/bootstrap/03-pki.sh --verify-only
```
