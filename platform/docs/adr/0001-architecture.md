# ADR-0001: Bare-metal Çok-Kiracılı Internal Developer Platform Mimarisi

| Alan | Değer |
|---|---|
| Durum | Kabul edildi (Accepted) |
| Tarih | 2026-09-14 |
| Karar vericiler | Platform Ekibi |
| Kapsam | Katman mimarisi + temel teknoloji seçimleri |
| Yerini aldığı ADR | — |

---

## Context (Bağlam)

Kendi veri merkezimizde, bare-metal sunucular üzerinde çalışan, birden fazla ürün
ekibine (tenant) hizmet veren bir **Internal Developer Platform (IDP)** kuruyoruz.

### Kısıtlar

1. **Bulut sağlayıcı yok.** Yönetilen LoadBalancer, yönetilen blok/obje depolama,
   yönetilen KMS, yönetilen Kubernetes control plane, yönetilen PostgreSQL — hiçbiri yok.
   Bir bulut sağlayıcının ücretsiz verdiği her primitifi kendimiz üretmek zorundayız.
2. **Çok-kiracılılık (multi-tenancy) zorunlu.** Tek bir fiziksel kümede birden fazla
   ekip barınacak. Bir tenant'ın diğerinin ağ trafiğini görmesi, kotasını tüketmesi
   veya secret'ına erişmesi kabul edilemez.
3. **Self-servis zorunlu.** Platform ekibi 4 kişi; ürün ekibi sayısı iki haneli.
   Her namespace, her veritabanı, her ingress için ticket açılan bir model ölçeklenmez.
   Platform ekibi **ticket işleyicisi değil, API sağlayıcısı** olmalı.
4. **Denetlenebilirlik (auditability).** Kimin ne zaman hangi kaynağı istediği,
   kimin onayladığı ve neyin canlıya gittiği geriye dönük izlenebilir olmalı.
5. **Geri dönülebilirlik.** Bir tenant'ın altyapısını silmek, yeniden kurmak ve
   felaket sonrası geri getirmek tekrarlanabilir bir işlem olmalı.

### Sorun

Bare-metal'de "self-servis altyapı" iki farklı problemin birleşimidir:

- **Underlay problemi:** Ağ, yük dengeleme ve depolama primitiflerini yoktan var etmek.
- **Control plane problemi:** Bu primitifleri, ürün ekiplerinin güvenle tüketebileceği
  yüksek seviyeli, kısıtlı ve doğrulanmış bir API'ye dönüştürmek.

Bu iki problemi tek bir katmanda çözmeye çalışmak (örneğin "her şey Helm chart"),
underlay değişikliklerinin tenant API'sini kırmasına ve tenant taleplerinin
altyapı detaylarına sızmasına yol açar.

---

## Decision (Karar)

### 1. Katmanlı mimari

Platformu, her biri bir altındakinin üzerine kurulan ve **yalnızca bir aşağıdaki
katmana bağımlı olan** 7 katman olarak inşa ediyoruz:

```
┌──────────────────────────────────────────────────────────────┐
│  L7  Developer Portal        Backstage                        │  ← İnsan arayüzü
│      (software catalog, scaffolder, TechDocs)                 │
├──────────────────────────────────────────────────────────────┤
│  L6  Tenant API              Crossplane XRD + KCL Composition  │  ← Sözleşme
│      (XTenant, XDatabase, XBucket, XApp)                      │
├──────────────────────────────────────────────────────────────┤
│  L5  Guardrails              Kyverno (validate/mutate/generate)│  ← Zorlama
├──────────────────────────────────────────────────────────────┤
│  L4  Platform Servisleri     Harbor, Keycloak, CloudNativePG,  │  ← Yetenekler
│      ESO, kube-prometheus-stack, OpenCost, Velero             │
├──────────────────────────────────────────────────────────────┤
│  L3  Kimlik & PKI            Vault + cert-manager + ESO        │  ← Güven
├──────────────────────────────────────────────────────────────┤
│  L2  Underlay                Cilium, MetalLB, Rook-Ceph        │  ← Primitifler
├──────────────────────────────────────────────────────────────┤
│  L1  Bootstrap               ArgoCD (app-of-apps)              │  ← Uzlaşma motoru
└──────────────────────────────────────────────────────────────┘
```

Repo dizin yapısı bu katmanlarla **birebir** eşleşir: `bootstrap/`, `underlay/`,
`pki/`, `control-plane/`, `policies/`, `compositions/`, `backstage/`.

Kural: **bir katman, kendisinden yukarıdaki bir katmana bağımlı olamaz.**
Bu, kurulum sırasını (bootstrap order) ve felaket sonrası kurtarma sırasını
deterministik kılar.

### 2. Teknoloji seçimleri

| Katman | Seçim | Alternatifler |
|---|---|---|
| GitOps | ArgoCD | Flux, Helmfile, düz `kubectl apply` |
| CNI | Cilium (kube-proxy replacement, Gateway API, Hubble) | Calico, Flannel, Antrea |
| L2/L3 LB | MetalLB (L2 mode → ileride BGP) | kube-vip, HAProxy + keepalived |
| Depolama | Rook-Ceph (RBD + CephFS + RGW) | Longhorn, OpenEBS, NFS |
| Registry | Harbor | Quay, Nexus, distribution |
| Kimlik | Keycloak (OIDC) | Dex, Authentik |
| Altyapı API | Crossplane v2 + KCL composition functions | Terraform, Pulumi, Helm, Operator SDK |
| Politika | Kyverno | OPA/Gatekeeper, Kubewarden |
| Sertifika/Secret | cert-manager + Vault + External Secrets Operator | Sealed Secrets, SOPS, cert-manager self-signed |
| Veritabanı | CloudNativePG | Zalando postgres-operator, StatefulSet + el ile |
| Portal | Backstage | Port, kendi yazdığımız UI |
| Gözlemlenebilirlik | kube-prometheus-stack | Grafana Agent + Mimir, VictoriaMetrics |
| Maliyet | OpenCost | Kubecost (ticari), kendi metrik hesabımız |
| Yedekleme | Velero (Ceph RGW backend) | Kasten K10, kendi CronJob'larımız |

Aşağıda, gerekçesi en tartışmalı olan dört seçim ayrıntılandırılmıştır.

---

### Karar 2.1 — Altyapı API'si olarak Crossplane, Terraform değil

**Terraform'u birincil araç olarak seçmiyoruz.** Terraform, repo içinde
ikincil ve dar bir rolde kalır: küme *öncesi* fiziksel/dışsal kaynaklar
(DNS zone delegasyonu, switch konfigürasyonu, ilk sanal makine/PXE provizyonu).
Küme *içindeki* tenant kaynakları için tek API Crossplane'dir.

**Gerekçe:**

1. **Uzlaşma (reconciliation) modeli.** Terraform, *çalıştırıldığı anda* uzlaşan
   bir CLI'dır. Arada biri elle bir kaynağı değiştirirse, bir sonraki `apply`'a
   kadar drift fark edilmez. Crossplane bir Kubernetes controller'ıdır: sürekli
   uzlaşır. Self-servis bir platformda drift'in dakikalar içinde düzeltilmesi,
   saatler/günler sonra düzeltilmesinden niteliksel olarak farklıdır.

2. **State problemi.** Terraform state'i, kendisi korunması, kilitlenmesi ve
   yedeklenmesi gereken ayrı bir kritik varlıktır. Bare-metal'de bunun için
   ayrıca bir S3+DynamoDB muadili (Ceph RGW + kilit mekanizması) kurmamız
   gerekirdi. Crossplane'de state, kaynağın kendisi ve `status` alanıdır;
   etcd zaten yedeklediğimiz bir yerdir. **Bir kritik varlık eksildi.**

3. **Self-servis yüzeyi.** Terraform ile self-servis, ürün ekibine ya
   `terraform apply` yetkisi vermek (çok geniş, kısıtlanamaz) ya da bir CI
   pipeline'ı arkasına gizlemek (bizim yazıp bakımını yapacağımız yeni bir
   ürün) demektir. Crossplane'de self-servis yüzeyi **Kubernetes RBAC**'tır —
   zaten kurduğumuz, zaten denetlediğimiz, zaten Keycloak'a bağladığımız
   mekanizma. Yeni bir yetkilendirme sistemi icat etmiyoruz.

4. **Tüketici ergonomisi.** Ürün ekipleri zaten YAML ve `kubectl` biliyor.
   `kubectl get xtenant` ile durum görmek, HCL öğrenip state dosyası okumaktan
   düşük sürtünmelidir. Crossplane'in `XTenant` gibi bir XRD'si, ekip için
   tıpkı bir `Deployment` gibi görünür.

5. **Bileşim (composition).** Crossplane v2'nin XRD + Composition modeli, tam
   olarak ihtiyacımız olan şeyi verir: **"bir tenant" gibi yüksek seviyeli bir
   kavramı, 15 alt kaynağa açan ve tüketiciden bu 15'ini gizleyen bir soyutlama.**
   Terraform modülü bunu benzer biçimde yapar ama modülün arkasındaki
   yaşam döngüsünü (silme sırası, finalizer, sahiplik) Kubernetes garbage
   collection kadar güvenilir biçimde yönetmez.

**Bedel (kabul ettiğimiz):**
- Crossplane provider ekosistemi, Terraform provider ekosisteminden dar.
  Bu bizi çok az etkiliyor çünkü bare-metal'de zaten bulut provider'ı kullanmıyoruz;
  hedeflerimizin çoğu `provider-kubernetes` ve `provider-helm` ile ulaşılabilir.
- Composition hata ayıklaması (debugging), `terraform plan` kadar okunaklı değildir.
  Bunu, Karar 2.4'teki KCL seçimi ve `crossplane render` ile CI'da plan üreterek
  hafifletiyoruz.

---

### Karar 2.2 — CNI olarak Cilium

**Gerekçe:**

1. **Kimlik tabanlı ağ politikası.** Çok-kiracılı bir kümede asıl ihtiyaç
   "IP A, IP B ile konuşabilir mi" değil, "tenant-a'nın frontend'i, tenant-b'nin
   veritabanıyla konuşabilir mi"dir. Cilium'un eBPF tabanlı kimlik (identity)
   modeli, politikayı IP'ye değil etikete bağlar — pod'lar sürekli yeniden
   yaratılırken tek doğru yaklaşım budur. `CiliumNetworkPolicy`, standart
   `NetworkPolicy`'nin veremediği L7 (HTTP yolu/metodu, DNS adı) kuralını verir;
   bu, tenant'ın dış dünyaya çıkışını DNS adıyla kısıtlamamızı sağlar.

2. **kube-proxy replacement.** Bare-metal'de iptables tabanlı kube-proxy,
   servis sayısı arttıkça doğrusal olmayan biçimde yavaşlar. Cilium'un eBPF
   tabanlı servis yük dengelemesi bu sınırı ortadan kaldırır ve aynı zamanda
   bir bileşeni (kube-proxy) tamamen sistemden çıkarır — **işletilecek bir
   parça eksildi.**

3. **Gözlemlenebilirlik (Hubble).** Çok-kiracılı bir platformda en sık gelen
   destek talebi "benim servisim X'e ulaşamıyor"dur. Hubble, hangi politikanın
   hangi akışı düşürdüğünü paket düzeyinde gösterir. Calico ile bu görünürlük
   için ayrıca bir şey kurmamız gerekirdi. **Destek maliyetini doğrudan düşürür.**

4. **Gateway API + L2/BGP entegrasyonu.** Cilium, Gateway API'yi yerel olarak
   uygular ve MetalLB ile temiz biçimde birlikte çalışır; ileride MetalLB'yi
   Cilium'un kendi BGP control plane'i ile değiştirme yolu açık kalır
   (bkz. Consequences).

**Bedel:** eBPF, ekip için iptables'tan daha dik bir öğrenme eğrisidir ve
çekirdek (kernel) sürümü üzerinde alt sınır dayatır. Bunu, node imajı için
minimum çekirdek sürümünü standartlaştırarak kabul ediyoruz.

---

### Karar 2.3 — Vault destekli PKI (self-signed veya tek başına cert-manager değil)

Küme içi tüm sertifikalar, **Vault'un PKI secrets engine'i** tarafından
imzalanır; cert-manager bu Vault issuer'ını kullanarak sertifikaları alır,
dağıtır ve yeniler. Uygulama secret'ları Vault'ta tutulur ve kümeye
External Secrets Operator ile yansıtılır.

**Gerekçe:**

1. **Kök anahtarın (root key) küme dışında olması.** cert-manager'ın kendi
   `SelfSigned`/`CA` issuer'ı kullanılırsa, kök özel anahtar bir Kubernetes
   Secret'ında, yani etcd'de, base64 olarak durur. etcd yedeğini ele geçiren
   herkes tüm platformun kimliğini taklit edebilir. Vault'ta kök anahtar
   asla dışarı çıkmaz — imzalama Vault içinde olur. **Bu, kümenin tamamen
   kaybedildiği senaryoda güven zincirinin hayatta kalması demektir.**

2. **Tek bir güven kökü, çok sayıda tüketici.** Sertifika ihtiyacımız yalnızca
   ingress TLS değil: Harbor, Keycloak, CloudNativePG istemci sertifikaları,
   iç mTLS, webhook sertifikaları ve tenant'ların kendi iç servisleri.
   Bunların hepsinin **aynı, denetlenebilir** kökten gelmesi, güven zincirini
   tek bir yerde döndürülebilir (rotate) kılar.

3. **Kısa ömür + otomatik yenileme.** Vault'ta rol başına maksimum TTL
   dayatılabilir (örn. 90 gün, iç mTLS için 24 saat). cert-manager yenilemeyi
   otomatik yapar. Elle sertifika yenileme diye bir operasyon kalmaz —
   bare-metal'de en sık görülen kesinti nedenlerinden biri ortadan kalkar.

4. **Kiracı başına yalıtım.** Vault PKI rolleri, `tenant-<name>` başına
   ayrı tanımlanır ve `allowed_domains` ile o tenant'ın alt alan adına
   kısıtlanır. Bir tenant, başka bir tenant'ın adına geçerli sertifika
   çıkartamaz. Düz cert-manager CA issuer'ı ile bu kısıt uygulanamaz.

5. **Secret ve PKI'ın tek sistemde birleşmesi.** Vault zaten dinamik veritabanı
   kimlik bilgileri ve uygulama secret'ları için gerekli. PKI'ı da aynı sisteme
   koyarak **ikinci bir kritik sistem işletmekten kaçınıyoruz.** ESO, Vault'u
   kümeye tek yönlü (Vault → küme) yansıtır; secret'lar hiçbir zaman Git'e girmez.

**Bedel:** Vault'un kendisi bir kritik bağımlılıktır ve **mühürsüzleme
(unseal)** operasyonu gerektirir. Bunu kabul ediyoruz; unseal prosedürü ve
kök anahtar paylaşımı (Shamir shares) ayrı bir runbook'ta belgelenecektir.
Vault'un kümeden bağımsız kalabilmesi için `pki/` katmanı, `control-plane/`
katmanının *altındadır* — Vault çökerse control plane kurtarılabilir, tersi değil.

---

### Karar 2.4 — Composition mantığı için KCL composition function (Patch & Transform değil)

Crossplane Composition'ları, `function-kcl` üzerinden yazılmış **KCL**
programları olarak yazılır.

**Gerekçe:**

1. **Patch & Transform'un ifade gücü yetmiyor.** Bizim `XTenant` bileşimimizin
   yapması gerekenler: tier'a (small/medium/large) göre ResourceQuota değerleri
   hesaplamak, opsiyonel bileşenleri (veritabanı istendi mi?) koşullu üretmek,
   tenant'ın istediği ortam listesi üzerinde döngü kurup her biri için namespace
   yaratmak. **Koşul, döngü ve aritmetik** demektir bu. P&T'nin YAML patch
   dizileri bunu ya hiç yapamaz ya da okunamaz hale gelir.

2. **KCL, Python/Go function'a göre daha dar ve daha güvenli.** Alternatif,
   `function-python` veya Go ile yazılmış bir function'dır. Bunlar tam
   programlama dilleridir: ağ çağrısı yapabilir, dosya okuyabilir, sonsuz
   döngüye girebilir. KCL **konfigürasyon için tasarlanmış, yan etkisiz
   (side-effect-free), sonlanması garanti** bir dildir. Bir composition'ın
   yapabileceklerini dilin kendisiyle sınırlamak, bir güvenlik sınırıdır.

3. **Şema ve tip doğrulaması derleme zamanında.** KCL'in kendi şema sistemi
   vardır; tier değeri `small|medium|large` dışında bir şey olamaz ve bu
   hata, kaynak kümeye ulaşmadan **CI'da** yakalanır. YAML patch'te aynı
   hata, çalışma zamanında yarı-oluşmuş bir kaynak olarak görünür.

4. **Test edilebilirlik.** KCL modülleri birim testi yazılabilir ve
   `crossplane render` ile CI'da "bu XTenant şu 14 kaynağa açılır" çıktısı
   golden-file olarak sabitlenebilir. Bu bize, **Terraform'da kaybettiğimiz
   `plan` deneyimini geri kazandırır** (bkz. Karar 2.1 bedeli).

5. **Yeniden kullanım.** Tier tanımları, zorunlu etiket seti ve isimlendirme
   kuralları tek bir KCL modülünde tanımlanıp tüm composition'lar tarafından
   import edilir. YAML'da bu, kopyala-yapıştır demektir.

**Bedel:** KCL, ekibin öğrenmesi gereken yeni bir dildir ve Crossplane
ekosisteminde Go function'lardan daha az yaygındır. Bunu, composition
mantığını `compositions/kcl/` altında az sayıda, iyi belgelenmiş modülde
toplayarak ve karmaşıklığı sınırlı tutarak kabul ediyoruz.

---

### 3. Tenant talep akışı (self-servis sözleşmesi)

```
Geliştirici                     tenant-requests repo            platform kümesi
    │                                   │                              │
    │ 1. Backstage scaffolder            │                              │
    ├──────────────────────────────────▶ │                              │
    │    (veya elle PR)                  │                              │
    │                                   │                              │
    │                              2. PR: tenants/<name>.yaml           │
    │                                 CI: KCL schema + Kyverno CLI      │
    │                                 (dry-run doğrulama)               │
    │                                   │                              │
    │                              3. Platform ekibi onayı (CODEOWNERS) │
    │                                   │                              │
    │                              4. merge ──▶ ArgoCD sync ───────────▶│
    │                                   │                              │
    │                                   │       5. XTenant yaratılır    │
    │                                   │          ↓ KCL composition    │
    │                                   │       Namespace(ler)          │
    │                                   │       ResourceQuota/LimitRange│
    │                                   │       CiliumNetworkPolicy     │
    │                                   │       RBAC (Keycloak grubu)   │
    │                                   │       Harbor projesi          │
    │                                   │       Vault PKI rolü + policy │
    │                                   │       ESO SecretStore         │
    │                                   │       Ceph quota / RGW bucket │
    │                                   │       CNPG Cluster (ops.)     │
    │                                   │       ServiceMonitor          │
    │                                   │       Velero Schedule         │
    │                                   │                              │
    │ 6. kubectl get xtenant <name> ◀────────────────────────────────────┤
```

**Neden ayrı bir `tenant-requests` reposu?**

- **Farklı yazma hakkı.** `platform` reposuna yalnızca platform ekibi yazar.
  `tenant-requests`'e her ürün ekibi PR açabilir. Aynı repoda bunu CODEOWNERS
  ile yapmak mümkün ama kaza payı yüksektir; ayrı repo, yanlışlıkla underlay
  değiştiren bir PR'ın var olamamasını sağlar.
- **Farklı değişim hızı.** Tenant talepleri günlük, platform değişiklikleri
  haftalık/aylık gelir. Ayırmak, platform reposunun commit geçmişini
  okunabilir tutar.
- **Denetim kaydı.** Bir tenant'ın kotasının ne zaman, kim tarafından, hangi
  gerekçeyle artırıldığı tek bir repoda, PR geçmişi olarak durur.

---

## Consequences (Sonuçlar)

### Olumlu

1. **Platform ekibi ticket işlemez.** Tenant yaratmak bir PR merge'üdür;
   kapasite artırmak bir alan değişikliğidir. Ekip zamanı, tek tek talepleri
   karşılamak yerine soyutlamaları iyileştirmeye gider.
2. **Tek doğruluk kaynağı Git'tir.** Kümedeki her şey (secret değerleri hariç)
   Git'te bir dosyaya karşılık gelir. Felaket kurtarma senaryosu
   "ArgoCD'yi kur, app-of-apps'ı işaret et, bekle"ye indirgenir.
3. **Kurulum sırası deterministiktir.** Katmanlar arası tek yönlü bağımlılık,
   `bootstrap → underlay → pki → control-plane → policies → compositions → backstage`
   sırasını hem kurulumda hem kurtarmada geçerli kılar.
4. **Güvenlik sınırları savunulabilirdir.** Her sınır ayrı bir mekanizmayla
   zorlanır: ağ → Cilium identity, kaynak → ResourceQuota, kimlik → Keycloak+RBAC,
   secret → Vault policy, imaj → Harbor projesi, ve hepsinin üstünde Kyverno
   ihlal edilemez bir taban dayatır.
5. **Maliyet kiracıya atfedilebilir.** Zorunlu `cost-center` etiketi + OpenCost,
   geri ödeme (chargeback/showback) raporunu doküman değil veri haline getirir.

### Olumsuz / Kabul edilen riskler

1. **Yüksek başlangıç karmaşıklığı.** 13 bileşenlik bir yığın, ilk tenant'tan
   *önce* çalışır durumda olmalıdır. İlk değer teslimi geç gelir. Bunu kabul
   ediyoruz; alternatif, elle kurulmuş ve 6 ay sonra çözülemeyen bir küme.
2. **Crossplane v2 + KCL function görece yeni.** Sürüm yükseltmelerinde kırıcı
   değişiklik riski var. Azaltma: composition'ların golden-file testleri CI'da,
   ve sürümler `bootstrap/` içinde sabitlenmiş (pinned) olacak.
3. **Vault tek hata noktasıdır (unseal dahil).** Vault erişilemezse yeni
   sertifika ve yeni secret üretilemez (mevcut olanlar çalışmaya devam eder).
   Azaltma: HA modda çalıştırma, unseal runbook'u, Vault'un `pki/` katmanında
   control-plane'in *altında* konumlandırılması.
4. **Rook-Ceph, operasyonel olarak yığındaki en ağır bileşendir.** Disk
   arızası, yeniden dengeleme (rebalance) ve kapasite planlaması gerçek bir
   operasyon yüküdür. Kabul ediyoruz: bare-metal'de ReadWriteMany + obje
   depolama + blok depolamayı tek sistemden almanın başka yolu yok, ve
   Velero'nun yedek hedefi olarak RGW zaten gerekli.
5. **MetalLB L2 modu, ölçek sınırlıdır.** L2 modda tüm trafik tek bir düğümden
   geçer ve failover ARP'a bağlıdır. Kabul ediyoruz: ilk faz için yeterli.
   Çıkış yolu: ağ ekibiyle BGP peering kurulduğunda MetalLB BGP moduna veya
   Cilium'un BGP control plane'ine geçiş — bu, yalnızca `underlay/` katmanını
   etkiler, üst katmanlar değişmez. **Katmanlı mimarinin kazandırdığı tam olarak budur.**
6. **KCL bilgisi ekipte tek kişide yoğunlaşabilir (bus factor).** Azaltma:
   composition mantığını sınırlı tutmak, her KCL modülüne örnek girdi/çıktı
   eklemek, en az iki kişinin KCL PR'ı gözden geçirmesini zorunlu kılmak.

### Bu kararla kapanan yollar

- Tenant'lara doğrudan `cluster-admin` benzeri geniş yetki verilmesi.
- Küme içi kaynakların Terraform ile yönetilmesi.
- Elle (`kubectl apply`) yapılan kalıcı değişiklikler — ArgoCD bunları geri alır.
- Kümede tutulan kök CA özel anahtarı.

### Gözden geçirme tetikleyicileri

Bu ADR şu durumlarda yeniden değerlendirilir:
- Küme sayısı 1'den fazlaya çıktığında (fleet yönetimi ayrı bir ADR gerektirir).
- BGP peering mümkün olduğunda (MetalLB kararı).
- Crossplane v3 çıktığında.
- Tenant sayısı 25'i geçtiğinde (tek küme çok-kiracılılık sınırları).

---

## İlgili ADR'ler

- ADR-0002: *(planlandı)* Tenant yalıtım modeli — namespace mı, sanal küme mi
- ADR-0003: *(planlandı)* Veritabanı hizmet modeli ve yedekleme/geri yükleme SLO'su
- ADR-0004: *(planlandı)* Ağ politikası varsayılanı (default-deny) ve çıkış (egress) kontrolü
