# =============================================================================
# XTenant composition mantığı — function-kcl pipeline adımı
# ADR-0001 Karar 2.4.
#
# BU DOSYA CANONICAL KAYNAKTIR. `composition.yaml`'daki pipeline adımının
# `input.spec.source` alanı bu dosyanın İÇERİĞİYLE BİREBİR AYNI OLMALIDIR —
# function-kcl'nin resmi "inline source" biçimi, KCL'i doğrudan Composition
# YAML'ının içine gömmeyi ister (bkz. crossplane-contrib/function-kcl README,
# "OCI source" yalnızca bir registry'ye push edilmiş modüller için).
# Bu, teknik borç olarak PLATFORM_CONTEXT.md'de kayıtlıdır: iki dosyanın
# senkron kalması ELLE sağlanır; `tests/verify-sync.sh` bunu otomatik kontrol
# eder ve fark varsa CI'da/lokal olarak KIRMIZI verir.
#
# Yerel test (cluster'sız, saf KCL):
#   kclvm_cli run function.k -D params='{"oxr": {...}}'
# =============================================================================

oxr = option("params").oxr
spec = oxr.spec

teamName    = spec.teamName
costCenter  = spec.costCenter
environment = spec.environment
networkTier = spec.networkTier
quotaTier   = spec.quotaTier
oidcGroup   = spec.oidcGroup

# --- İsimlendirme (conventions.md §5, §2.1: tenant-<name>[-<env>]) ---------
nsName = "tenant-${teamName}-${environment}"

# --- Tier tanımları — TEK doğruluk kaynağı (conventions.md §4) -------------
# Bu görevde verilen değerler conventions.md §4.1'deki ESKİ tabloyla
# ÇELİŞİYORDU (2/4 CPU vb. yerine 4/16/64 CPU). Görevin verdiği sayılar
# burada kanonik kabul edildi ve conventions.md §4.1 BU DOSYAYLA EŞLEŞECEK
# ŞEKİLDE güncellendi (bkz. PLATFORM_CONTEXT.md Faz 6 günlüğü).
_tiers = {
    small = {cpu = "4", memory = "8Gi", pods = "10"}
    medium = {cpu = "16", memory = "32Gi", pods = "50"}
    large = {cpu = "64", memory = "128Gi", pods = "200"}
}
tier = _tiers[quotaTier]

# --- Zorunlu etiketler (conventions.md §3.1 + §3.2) ------------------------
labels = {
    "platform.internal/cost-center" = costCenter
    "platform.internal/owner" = "team-${teamName}"
    "platform.internal/environment" = environment
    "platform.internal/managed-by" = "crossplane"
    "platform.internal/tenant" = teamName
    "platform.internal/tier" = quotaTier
}

# Namespace'e ÖZEL ek etiketler — Pod Security Standards.
# policies/validation/08-require-pss-restricted.yaml BUNU ENFORCE EDER;
# burada üretilmezse composition'ın ürettiği HER namespace o politika
# tarafından reddedilir. "restricted" profili conventions.md'de henüz
# belgelenmemiş bir platform-genelinde varsayımdır (bkz. PLATFORM_CONTEXT.md
# teknik borcu) — tenant workload'larının hepsi non-root, salt-okunur
# root filesystem vb. kısıtlara uymak ZORUNDA kalır.
nsLabels = {
    **labels
    "pod-security.kubernetes.io/enforce" = "restricted"
    "pod-security.kubernetes.io/audit" = "restricted"
    "pod-security.kubernetes.io/warn" = "restricted"
}

_resAnno = lambda name: str -> {str:str} {
    {"krm.kcl.dev/composition-resource-name" = name}
}

# DÜZELTME (Faz 12b, GERÇEK bir kind cluster'ında keşfedildi): function-
# auto-ready (v0.5.0), Role/RoleBinding/ResourceQuota/LimitRange/
# CiliumNetworkPolicy gibi tiplerin NEDEN "Ready" kabul edilmediğini
# açıklayan hiçbir status.condition'a SAHİP DEĞİL — bu tipler için ne
# native bir "Ready" condition'ı ne de function-auto-ready'nin KENDİ
# healthchecks registry'sinde (v0.6.0'da eklendi, bkz. versions.env)
# kayıtlı bir kontrol var. Sonuç: XTenant.status'u KALICI OLARAK
# Ready=False kalıyordu (Synced=True olmasına, ve her kaynağın GERÇEKTEN
# doğru şekilde oluşmasına RAĞMEN) — canlı bir kind cluster'ında, XR'ı
# SIFIRDAN yeniden oluşturarak DOĞRULANDI (session cruft DEĞİL, gerçek
# bir composition eksikliği).
#
# Çözüm: bu tipler için function-kcl'nin KENDİ `krm.kcl.dev/ready: "True"`
# annotation'ı ile AÇIKÇA ready işaretleniyor — bu, Crossplane çekirdeğinin
# doğrudan onayladığı, function-auto-ready'den TAMAMEN bağımsız bir
# mekanizma (bkz. function-kcl README §"Readiness"). Yalnızca native bir
# Ready condition'ı OLMAYAN VE function-auto-ready'nin ASLA
# destekleyemeyeceği (statik, kontrolcüsüz) kaynak tipleri için kullanılır
# — Job/Namespace/ServiceAccount/ConfigMap gibi function-auto-ready'nin
# GERÇEKTEN doğru şekilde izleyebildiği tipler İÇİN KULLANILMAZ (o tipler
# için sahte "her zaman ready" zaten YANLIŞ OLURDU — ör. Job'ın GERÇEKTEN
# tamamlanıp tamamlanmadığı önemlidir).
_resAnnoAlwaysReady = lambda name: str -> {str:str} {
    {**_resAnno(name), "krm.kcl.dev/ready" = "True"}
}

# =============================================================================
# 1. Namespace
# =============================================================================
namespace = {
    apiVersion = "v1"
    kind = "Namespace"
    metadata = {
        name = nsName
        annotations = _resAnno("namespace")
        labels = nsLabels
    }
}

# =============================================================================
# 2. RBAC — Role (namespace-scoped) + RoleBinding (Keycloak OIDC grubuna)
# =============================================================================
role = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "Role"
    metadata = {
        name = "tenant-admin"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("role")
        labels = labels
    }
    # DÜZELTME (Faz 12g, code review #7): "networking.k8s.io" blanket wildcard
    # ("*" resource, "*" verb) tenant'a KENDİ NetworkPolicy/CiliumNetworkPolicy
    # kaynaklarını da create/update/delete YETKİSİ veriyordu. Kubernetes
    # NetworkPolicy (ve Cilium'un CNP karşılığı) modeli SALT-EKLEMELİ'dir
    # (allow-list) — tenant, defaultDenyPolicy/tierNetworkPolicy'nin ÜSTÜNE
    # kendi serbest bırakan bir NetworkPolicy YAZARAK platformun zero-trust
    # ağ izolasyonunu (örn. tüm namespace'lere/internete egress) BAŞKA BİR
    # tenant'ın izni olmadan genişletebilirdi — bu bir yetki yükseltmesi.
    # networking.k8s.io iki alt kümeye ayrıldı: Ingress (tenant'ın meşru
    # self-service ihtiyacı — tam CRUD) ve NetworkPolicy (yalnızca salt-okunur
    # görünürlük; create/update/delete/patch YOK).
    rules = [
        {
            apiGroups = ["", "apps", "batch"]
            resources = ["*"]
            verbs = ["*"]
        }
        {
            apiGroups = ["networking.k8s.io"]
            resources = ["ingresses", "ingresses/status"]
            verbs = ["*"]
        }
        {
            apiGroups = ["networking.k8s.io"]
            resources = ["networkpolicies"]
            verbs = ["get", "list", "watch"]
        }
    ]
}

roleBinding = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "RoleBinding"
    metadata = {
        name = "tenant-admin-binding"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("rolebinding")
        labels = labels
    }
    subjects = [
        {
            kind = "Group"
            apiGroup = "rbac.authorization.k8s.io"
            # "oidc:" öneki — API server'ın `--oidc-groups-prefix=oidc:` ile
            # kurulduğu VARSAYIMI (bkz. docs/runbooks/k8s-api-server-oidc.md,
            # açık karar #13/teknik borç #17'nin çözümü). Önek olmadan
            # (API server OIDC ayarları henüz yoksa) bu RoleBinding zaten
            # HİÇBİR OIDC token'ıyla eşleşmez — dolayısıyla önek eklemek
            # MEVCUT (zaten işlevsiz) durumu KÖTÜLEŞTİRMEZ, yalnızca OIDC
            # kurulduğunda doğru çalışmasını sağlar.
            name = "oidc:${oidcGroup}"
        }
    ]
    roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind = "Role"
        name = "tenant-admin"
    }
}

# =============================================================================
# 3. ResourceQuota + LimitRange (quotaTier'a göre)
# =============================================================================
resourceQuota = {
    apiVersion = "v1"
    kind = "ResourceQuota"
    metadata = {
        name = "tenant-quota"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("resourcequota")
        labels = labels
    }
    spec.hard = {
        "requests.cpu" = tier.cpu
        "requests.memory" = tier.memory
        "limits.cpu" = tier.cpu
        "limits.memory" = tier.memory
        "pods" = tier.pods
    }
}

limitRange = {
    apiVersion = "v1"
    kind = "LimitRange"
    metadata = {
        name = "tenant-limits"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("limitrange")
        labels = labels
    }
    spec.limits = [
        {
            type = "Container"
            defaultRequest = {cpu = "100m", memory = "128Mi"}
            default = {cpu = "500m", memory = "512Mi"}
        }
    ]
}

# =============================================================================
# 4. CiliumNetworkPolicy — default-deny + networkTier'a göre parametrik izin
# =============================================================================
_allowDns = {
    toEndpoints = [
        {
            matchLabels = {
                "k8s:io.kubernetes.pod.namespace" = "kube-system"
                "k8s:k8s-app" = "kube-dns"
            }
        }
    ]
    toPorts = [
        {
            ports = [
                {port = "53", protocol = "UDP"}
                {port = "53", protocol = "TCP"}
            ]
            rules.dns = [{matchPattern = "*"}]
        }
    ]
}

_intraTenantEgress = {
    toEndpoints = [
        {matchLabels = {"k8s:io.kubernetes.pod.namespace" = nsName}}
    ]
}

_intraTenantIngress = {
    fromEndpoints = [
        {matchLabels = {"k8s:io.kubernetes.pod.namespace" = nsName}}
    ]
}

# DÜZELTME (Faz 12g, code review #6): "isolated" tier intra-tenant trafiği
# TAMAMEN kesiyordu (yalnızca DNS) — ama tenant'ın kendi Postgres'i (CNPG
# composition'ı) platform tarafından sağlanan, tenant'ın seçmediği ZORUNLU
# bir bağımlılık; bir "peer app pod" değil. Bu kural olmadan isolated tier'daki
# HİÇBİR uygulama pod'u kendi veritabanına bağlanamıyordu. "custom" tier'a
# BİLİNÇLİ OLARAK dokunulmadı — kontrat: tenant kendi CNP'sini kendisi ekler.
_allowTenantPostgres = {
    toEndpoints = [
        {
            matchLabels = {"k8s:io.kubernetes.pod.namespace" = nsName}
            matchExpressions = [
                {key = "cnpg.io/cluster", operator = "Exists"}
            ]
        }
    ]
    toPorts = [
        {ports = [{port = "5432", protocol = "TCP"}]}
    ]
}

# isolated: DNS + kendi Postgres'i. open: DNS + tenant-içi serbest (Postgres
# zaten dahil). custom: boş (default-deny dışında hiçbir kural — tenant
# sonradan kendi CNP'sini ekler).
_egressByTier = {
    "isolated" = [_allowDns, _allowTenantPostgres]
    "open" = [_allowDns, _intraTenantEgress]
    "custom" = []
}
_ingressByTier = {
    "isolated" = []
    "open" = [_intraTenantIngress]
    "custom" = []
}

# default-deny: endpointSelector {} + boş ingress/egress = hiçbir şeye izin
# vermeyen taban politika (Cilium'da boş kural listesi = deny-all o yönde).
defaultDenyPolicy = {
    apiVersion = "cilium.io/v2"
    kind = "CiliumNetworkPolicy"
    metadata = {
        name = "tenant-default-deny"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("networkpolicy-deny")
        labels = labels
    }
    spec = {
        endpointSelector = {}
        ingress = []
        egress = []
    }
}

# networkTier izinleri — AYRI bir politika olarak (default-deny'nin üstüne
# eklenir; Cilium'da aynı endpointSelector'a uygulanan birden çok
# CiliumNetworkPolicy'nin izinleri BİRLEŞİR/toplanır).
tierNetworkPolicy = {
    apiVersion = "cilium.io/v2"
    kind = "CiliumNetworkPolicy"
    metadata = {
        name = "tenant-network-tier"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("networkpolicy-tier")
        labels = labels
    }
    spec = {
        endpointSelector = {}
        egress = _egressByTier[networkTier]
        ingress = _ingressByTier[networkTier]
    }
}

# =============================================================================
# 5. ServiceAccount
# =============================================================================
serviceAccount = {
    apiVersion = "v1"
    kind = "ServiceAccount"
    metadata = {
        name = "tenant-workload"
        namespace = nsName
        annotations = _resAnno("serviceaccount")
        labels = labels
    }
}

# =============================================================================
# 6. Vault Kubernetes-auth Role + PKI role — native Job (Faz 12b'de
#    provider-terraform'dan TAŞINDI, bkz. PLATFORM_CONTEXT.md Faz 12b günlüğü)
#
# ÖNCEKİ TASARIM (provider-terraform Workspace) GERÇEK bir kind cluster'ında
# KALICI OLARAK bloke oluyordu: crossplane-contrib/provider-terraform'un
# Observe() adımı, HENÜZ apply edilmemiş bir workspace'te KOŞULSUZ `terraform
# state list` çağırıyor ve bu, Terraform CLI'ın kendi "No state file was
# found!" hatasıyla BAŞARISIZ oluyor — Create()'e HİÇ ulaşılamıyor. Bu,
# provider'ın v0.19.0'dan v1.2.0'a kadar (canlı test edildi) DEĞİŞMEYEN,
# upstream bir yapısal sınırlama (provider kaynağı: internal/terraform/
# terraform.go, Resources()).
#
# Bu Job'ın yaptığı 5 Vault yazması zaten DOĞASI GEREĞİ idempotent (`vault
# policy write` / `vault write auth/.../role/...` PUT semantiğinde) — yani
# Terraform'un durum takibi (state) hiç GEREKMİYOR. ADR-0001 Karar 2.1'in
# kendi ilkesiyle de ÖRTÜŞÜYOR: provider-terraform yalnızca Crossplane'in
# NATİF kaynaklarıyla ifade EDİLEMEYEN şeyler için escape hatch'tir — ve bir
# Job + ServiceAccount + Vault kubernetes-auth, native bir Crossplane
# kaynağıdır (rbac-composed-resources.yaml'daki aggregate ClusterRole'e
# `batch/jobs` eklenerek Crossplane'in KENDİSİ tarafından uygulanabiliyor,
# hiçbir ek provider GEREKMİYOR).
#
# Kimlik: sabit bir ServiceAccount "vault-tenant-bootstrap" (crossplane-
# system, STATİK — platform/pki/vault/README.md ve bootstrap/03-pki.sh'te
# kurulur), Vault k8s-auth role "vault-tenant-bootstrap" → policy
# "provider-terraform" (AYNI dar kapsam, bkz. policies/provider-terraform-
# policy.hcl — yalnızca `tenant-*` ve `eso-tenant-*` path'leri).
#
# Bu Job, YALNIZCA şunları yaratır (tüm adlar `<nsName>` = tam namespace,
# "tenant-<team>-<env>", ÜZERİNDEN — team-only DEĞİL, bkz. aşağıdaki
# düzeltme notu: bu, hem postgresql/function.k'nin `tenantRef` ile ürettiği
# rol adıyla EŞLEŞMESİ hem de aynı takımın dev/prod ortamlarının BİRBİRİNİ
# EZMEMESİ için ZORUNLUDUR):
#   - Vault k8s-auth role "tenant-<nsName>": bound_service_account_names=
#     tenant-workload, bound_service_account_namespaces=<nsName> — SADECE
#     bu tenant'ın SA'sı bu role ile auth olabilir.
#   - Vault policy "tenant-<nsName>": SADECE
#     pki-int-<environment>/issue/tenant-<nsName> yoluna erişim.
#   - Vault PKI role "tenant-<nsName>" (pki-int-<environment> mount'unda):
#     allowed_domains="<nsName>.svc.cluster.local",
#     allow_subdomains=true — yalnızca *.<nsName>.svc.cluster.local
#     için sertifika/kimlik bilgisi üretilebilir. Başka bir tenant'ın domain'i
#     İSTENEMEZ (kabul kriteri: iki tenant birbirinin domain'ine erişemez).
#   - Vault policy + k8s-auth role "eso-tenant-<nsName>": açık karar #16'nın
#     çözümü — HER tenant kendi ESO kimliğini alır (paylaşımlı DEĞİL),
#     yalnızca KENDİ `kv/data/tenants/<nsName>/*` yoluna erişimle. Rol adı
#     `postgresql/function.k`'nin `role = "eso-tenant-${tenantRef}"` ile
#     ÜRETTİĞİ değerle BİREBİR aynı olmalı (tenantRef = nsName).
#
# DÜZELTME (kod incelemesinde bulundu, GERÇEK bir üretim bug'ı): bu adlar
# ÖNCEDEN `<teamName>` (yalnızca takım adı, ortam YOK) kullanıyordu —
# (1) postgresql/function.k HER ZAMAN `<nsName>` ile üretilen bir rol adı
#     BEKLİYORDU, iki taraf ASLA eşleşmiyordu (SecretStore auth HER ZAMAN
#     başarısız); (2) aynı takımın dev/prod ortamları AYNI role/policy
#     adını PAYLAŞIYORDU, ikinci ortamın bootstrap Job'ı BİRİNCİSİNİN
#     `bound_service_account_namespaces` bağını SESSİZCE EZİYORDU.
#
# Job adı SABİT (tenant başına) — tüm girdiler (teamName/environment/nsName)
# XR'ın ömrü boyunca DEĞİŞMEZ, bu yüzden Job spec'i de değişmez; aynı ad ile
# tekrar apply zaten no-op'tur (Job şablonu immutable, Crossplane diff
# görmez). `ttlSecondsAfterFinished` ile tamamlanan Job'lar otomatik temizlenir.
# DÜZELTME (kod incelemesinde bulundu, GERÇEK bir bug): bu script'in
# Vault policy/auth-role adları ÖNCEDEN yalnızca `${teamName}` kullanıyordu
# (ör. `eso-tenant-acme`) — bu İKİ ayrı, gerçek üretim sorununa yol
# açıyordu:
#   (1) `postgresql/function.k`'nin ürettiği SecretStore, `eso-tenant-
#       ${tenantRef}` rolünü BEKLİYOR — `tenantRef` her zaman TAM namespace
#       adıdır (`tenant-<team>-<env>`, ör. "tenant-acme-dev"), team adı
#       DEĞİL. Rol adları burada team-only iken, postgres tarafı tam
#       namespace bekliyordu → İKİ TARAF ASLA EŞLEŞMİYORDU, SecretStore
#       kimlik doğrulaması HER ZAMAN başarısız olurdu.
#   (2) AYNI takımın `dev` ve `prod` ortamları AYNI Vault rolünü/policy'sini
#       paylaşıyordu (`tenant-acme`, ortam FARKI YOK) — ama rolün
#       `bound_service_account_namespaces` alanı ortama göre DEĞİŞİYORDU.
#       İkinci ortam bootstrap edildiğinde `vault write` (idempotent PUT)
#       BİRİNCİ ortamın namespace bağını SESSİZCE EZERDİ — iki ortam aynı
#       anda çalışırken erişim izolasyonu YOKTU.
# Çözüm: TÜM Vault tanımlayıcı adları (policy + auth role) `${nsName}`
# (tam namespace, zaten hem team hem env içerir) üzerinden üretiliyor —
# postgresql/function.k'nin `tenantRef` ile ÜRETTİĞİ AYNI değer, bu yüzden
# iki composition ARTIK KESİN olarak aynı rol adına varır.
_vaultBootstrapScript = """
set -e
# DÜZELTME (Faz 12g, code review #8): Vault listener'ı artık kendi
# PKI'sinden imzalı bir sertifikayla HTTPS dinliyor (bkz. bootstrap/
# 03-pki.sh:enable_vault_tls). VAULT_CACERT, aşağıdaki Job spec'inin
# "vault-ca" volume'ü ile mount edilen "vault-ca-bundle" ConfigMap'ini
# (vault namespace'i, root CA) işaret eder — bu olmadan `vault write`
# çağrılarının HEPSİ "x509: certificate signed by unknown authority" ile
# başarısız olurdu.
export VAULT_ADDR=https://vault-active.vault.svc.cluster.local:8200
export VAULT_CACERT=/etc/vault-ca/ca.crt
TOKEN=$(vault write -field=token auth/kubernetes/login role=vault-tenant-bootstrap jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token)
export VAULT_TOKEN=$TOKEN

vault policy write tenant-${nsName} - <<'EOT'
path "pki-int-${environment}/issue/tenant-${nsName}" {
  capabilities = ["create", "update"]
}
EOT

vault write auth/kubernetes/role/tenant-${nsName} \\
  bound_service_account_names=tenant-workload \\
  bound_service_account_namespaces=${nsName} \\
  token_policies=tenant-${nsName} \\
  token_ttl=3600

vault policy write eso-tenant-${nsName} - <<'EOT'
path "kv/data/tenants/${nsName}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/tenants/${nsName}/*" {
  capabilities = ["read", "list", "delete"]
}
# DÜZELTME (Faz 12g, code review #8): tenant'ın KENDİ cert-manager Issuer'ı
# (aşağıda), Vault'un artık HTTPS olan listener'ına GÜVENMEK için bir CA
# bundle Secret'ı gerektirir. Bootstrap (03-pki.sh:enable_vault_tls), CA
# zincirini TÜM tenant'ların PAYLAŞTIĞI, salt-okunur bu path'e yazar — path
# "tenants/*" ÖNEKİ ALTINDA DEĞİL, bilinçli olarak ayrı bir platform-genelinde
# path ("platform/vault-ca-bundle") — tenant izolasyonunu İHLAL ETMEZ çünkü
# CA sertifikası zaten GİZLİ DEĞİLDİR (bir CA sertifikasının KAMUYA açık
# olması PKI'nin doğası gereğidir).
path "kv/data/platform/vault-ca-bundle" {
  capabilities = ["read"]
}
EOT

vault write auth/kubernetes/role/eso-tenant-${nsName} \\
  bound_service_account_names=eso-tenant-secrets \\
  bound_service_account_namespaces=${nsName} \\
  token_policies=eso-tenant-${nsName} \\
  token_ttl=3600

# DÜZELTME (kod incelemesinde bulundu): max_ttl/ttl ÖNCEDEN 720h (30 gün)
# idi ama postgresql/function.k'nin ürettiği Certificate `duration=2160h`
# (90 gün) İSTİYOR — Vault, bir rolün max_ttl'ini AŞAN bir süre istenirse
# imzalama isteğini REDDEDER (bkz. Vault PKI API dokümantasyonu). 2160h'e
# çekildi — postgresql/function.k'deki Certificate'ın KENDİ yorumunun
# ZATEN iddia ettiği ("90 gün — tenant PKI rolünün max_ttl'i ile aynı")
# ama GERÇEKTE hiç doğru olmamış durumla eşleşecek şekilde.
vault write pki-int-${environment}/roles/tenant-${nsName} \\
  allowed_domains=${nsName}.svc.cluster.local \\
  allow_subdomains=true \\
  allow_bare_domains=false \\
  allow_glob_domains=false \\
  max_ttl=2160h \\
  ttl=2160h \\
  key_type=rsa \\
  key_bits=2048
"""

vaultBootstrapJob = {
    apiVersion = "batch/v1"
    kind = "Job"
    metadata = {
        name = "vault-bootstrap-${teamName}-${environment}"
        namespace = "crossplane-system"
        annotations = _resAnno("vault-bootstrap-job")
        labels = labels
    }
    spec = {
        backoffLimit = 6
        ttlSecondsAfterFinished = 3600
        template = {
            metadata = {
                labels = labels
            }
            spec = {
                serviceAccountName = "vault-tenant-bootstrap"
                restartPolicy = "OnFailure"
                # DÜZELTME (Faz 12g, code review #8): Vault HTTPS'e geçtikten
                # sonra bu Job'un `vault` CLI çağrılarının sunucu sertifikasına
                # GÜVENEBİLMESİ için root CA'yı mount eder (bkz. yukarıdaki
                # _vaultBootstrapScript'teki VAULT_CACERT).
                volumes = [{
                    name = "vault-ca"
                    configMap = {name = "vault-ca-bundle"}
                }]
                containers = [{
                    name = "vault"
                    image = "hashicorp/vault:1.18.1"
                    command = ["/bin/sh", "-c"]
                    args = [_vaultBootstrapScript]
                    volumeMounts = [{
                        name = "vault-ca"
                        mountPath = "/etc/vault-ca"
                        readOnly = True
                    }]
                    # DÜZELTME (Faz 12c, GERÇEK bir kind cluster'ında
                    # `require-pod-resources` Kyverno politikası Enforce
                    # moduna alınınca keşfedildi): bu container'ın hiç
                    # `resources` alanı YOKTU — policy'nin kendisi (Faz 6b'de
                    # yazıldı) HER container'da cpu/memory requests+limits
                    # ZORUNLU kılıyor; bu alan olmadan Job'un GERÇEK bir
                    # admission webhook'una karşı OLUŞTURULAMAYACAĞI, yalnızca
                    # policy Enforce moduna alınınca (canlı olarak) ortaya
                    # çıktı.
                    resources = {
                        requests = {cpu = "50m", memory = "64Mi"}
                        limits = {cpu = "200m", memory = "128Mi"}
                    }
                }]
            }
        }
    }
}

# --- 6b. ESO per-tenant ServiceAccount + token-mint RBAC --------------------
# `postgresql/function.k`'nin ürettiği SecretStore, bu ServiceAccount'u
# `serviceAccountRef` ile referans alır (ESO'nun KENDİ paylaşılan controller
# kimliği YERİNE) — yukarıdaki `eso_tenant` Vault k8s-auth role'ü SADECE bu
# SA'yı kabul eder.
esoServiceAccount = {
    apiVersion = "v1"
    kind = "ServiceAccount"
    metadata = {
        name = "eso-tenant-secrets"
        namespace = nsName
        annotations = _resAnno("eso-serviceaccount")
        labels = labels
    }
}

esoTokenRequestRole = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "Role"
    metadata = {
        name = "eso-tenant-secrets-tokenrequest"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("eso-tokenrequest-role")
        labels = labels
    }
    rules = [
        {
            apiGroups = [""]
            resources = ["serviceaccounts/token"]
            resourceNames = ["eso-tenant-secrets"]
            verbs = ["create"]
        }
    ]
}

esoTokenRequestRoleBinding = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "RoleBinding"
    metadata = {
        name = "eso-tenant-secrets-tokenrequest"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("eso-tokenrequest-rolebinding")
        labels = labels
    }
    subjects = [
        {
            kind = "ServiceAccount"
            # ESO'nun KENDİ controller SA'sı — external-secrets Helm chart'ının
            # varsayılan SA adı (bkz. control-plane/external-secrets/values.yaml.tpl).
            name = "external-secrets"
            namespace = "external-secrets"
        }
    ]
    roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind = "Role"
        name = "eso-tenant-secrets-tokenrequest"
    }
}

# =============================================================================
# 7. cert-manager namespaced Issuer — tenant'ın kendi Vault PKI rolüne bağlı
#
# NOT: `pki-int-<env>/sign/tenant-<teamName>` yoluna cert-manager'ın erişimi
# olması için platform/pki/vault/policies/cert-manager-policy.hcl
# `pki-int-*/sign/tenant-*` glob'unu içerecek şekilde GÜNCELLENDİ (Faz 3'ün
# dosyası, bu faz için genişletildi — bkz. PLATFORM_CONTEXT.md Faz 6 günlüğü).
# =============================================================================
# DÜZELTME (Faz 12g, code review #8): Vault listener'ı artık HTTPS —
# tenant Issuer'ının sunucu sertifikasına güvenebilmesi için, ESO ile aynı
# round-trip deseni kullanılıyor (bkz. postgresql/function.k §7'nin "neden
# ExternalSecret" yorumu): CA zinciri Vault'un KV'sinden çekilip
# `vault-ca-bundle` adında bir Secret'a yazılır, Issuer da o Secret'ı
# `caBundleSecretRef` ile referans alır (cert-manager'ın Vault issuer'ı
# yalnızca AYNI namespace'teki bir Secret'ı ya da inline `caBundle`'ı kabul
# eder — ConfigMap/cross-namespace YOK, bu yüzden ESO'nun caProvider'ı
# BURADA kullanılamaz).
vaultCaSecretStore = {
    apiVersion = "external-secrets.io/v1beta1"
    kind = "SecretStore"
    metadata = {
        name = "vault-ca-backend"
        namespace = nsName
        annotations = _resAnno("secretstore-ca")
        labels = labels
    }
    spec.provider.vault = {
        server = "https://vault-active.vault.svc.cluster.local:8200"
        caProvider = {
            type = "ConfigMap"
            name = "vault-ca-bundle"
            namespace = "vault"
            key = "ca.crt"
        }
        path = "kv"
        version = "v2"
        auth.kubernetes = {
            mountPath = "kubernetes"
            role = "eso-tenant-${nsName}"
            serviceAccountRef = {
                name = "eso-tenant-secrets"
                namespace = nsName
            }
        }
    }
}

vaultCaExternalSecret = {
    apiVersion = "external-secrets.io/v1beta1"
    kind = "ExternalSecret"
    metadata = {
        name = "vault-ca-bundle"
        namespace = nsName
        annotations = _resAnno("externalsecret-ca")
        labels = labels
    }
    spec = {
        refreshInterval = "1h"
        secretStoreRef = {name = "vault-ca-backend", kind = "SecretStore"}
        target.name = "vault-ca-bundle"
        data = [
            {
                secretKey = "ca.crt"
                remoteRef = {key = "platform/vault-ca-bundle", property = "ca.crt"}
            }
        ]
    }
}

issuer = {
    apiVersion = "cert-manager.io/v1"
    kind = "Issuer"
    metadata = {
        name = "tenant-issuer"
        namespace = nsName
        annotations = _resAnno("issuer")
        labels = labels
    }
    spec.vault = {
        server = "https://vault-active.vault.svc.cluster.local:8200"
        caBundleSecretRef = {name = "vault-ca-bundle", key = "ca.crt"}
        # DÜZELTME: PKI rolü adı artık `tenant-${nsName}` (bkz.
        # _vaultBootstrapScript) — burası ARTIK ${teamName} DEĞİL, aynı
        # role'e işaret etmeli, aksi halde imzalama "role not found" ile
        # başarısız olur.
        path = "pki-int-${environment}/sign/tenant-${nsName}"
        auth.kubernetes = {
            role = "cert-manager"
            mountPath = "/v1/auth/kubernetes"
            serviceAccountRef = {name = "cert-manager"}
        }
    }
}

# --- 7b. cert-manager'ın Issuer'a "kimlik ödünç alma" (ambient) ile auth
# olabilmesi için ServiceAccount + RBAC — Faz 11'de GERÇEK bir kind
# cluster'ında (Vault dahil) uçtan uca test edilirken KEŞFEDİLEN bir eksik:
# `Issuer.spec.vault.auth.kubernetes.serviceAccountRef` NAMESPACED bir
# Issuer için, İSİMLENDİRİLEN ServiceAccount'ın (burada "cert-manager")
# Issuer İLE AYNI namespace'te var OLMASINI ve cert-manager'ın KENDİ
# controller SA'sının o SA için TokenRequest oluşturabilmesini gerektirir
# — bu ikisi olmadan Issuer ASLA Ready olamaz (gerçek hata: "Failed to
# initialize Vault client: ... serviceaccounts \"cert-manager\" is
# forbidden"). Composition ÖNCEDEN yalnızca "tenant-workload" SA'sını
# üretiyordu, "cert-manager" SA'sını HİÇ üretmiyordu — bu GERÇEK bir
# üretim-engelleyici bug'dı, cert-manager'ın KENDİSİ kurulu olsa bile
# hiçbir tenant Issuer'ı asla Ready olamazdı.
certManagerServiceAccount = {
    apiVersion = "v1"
    kind = "ServiceAccount"
    metadata = {
        name = "cert-manager"
        namespace = nsName
        annotations = _resAnno("cert-manager-serviceaccount")
        labels = labels
    }
}

certManagerTokenRequestRole = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "Role"
    metadata = {
        name = "cert-manager-tokenrequest"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("cert-manager-tokenrequest-role")
        labels = labels
    }
    rules = [
        {
            apiGroups = [""]
            resources = ["serviceaccounts/token"]
            resourceNames = ["cert-manager"]
            verbs = ["create"]
        }
    ]
}

certManagerTokenRequestRoleBinding = {
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind = "RoleBinding"
    metadata = {
        name = "cert-manager-tokenrequest"
        namespace = nsName
        annotations = _resAnnoAlwaysReady("cert-manager-tokenrequest-rolebinding")
        labels = labels
    }
    subjects = [
        {
            kind = "ServiceAccount"
            # cert-manager'ın KENDİ controller SA'sı — platformun cert-manager
            # kurulumunun `cert-manager` namespace'inde `cert-manager` adlı
            # SA ürettiğini VARSAYAR (jetstack/cert-manager chart'ının
            # varsayılan SA adı — bkz. pki/cert-manager/values.yaml).
            name = "cert-manager"
            namespace = "cert-manager"
        }
    ]
    roleRef = {
        apiGroup = "rbac.authorization.k8s.io"
        kind = "Role"
        name = "cert-manager-tokenrequest"
    }
}

# =============================================================================
# 8. Backstage catalog-info — otomatik katalog kaydı (Faz 8)
#
# NEDEN ArgoCD post-sync hook DEĞİL: Backstage'in `catalog.providers.
# kubernetes` sağlayıcısı (app-config.yaml) bu ConfigMap'leri KENDİSİ,
# POLLING ile (60s aralıkla) tarar — ayrı bir hook/webhook/API çağrısı
# GEREKMEZ. Composition, provizyonun bir PARÇASI olarak veriyi üretir;
# Backstage onu KENDİ zamanlamasında keşfeder. Bu, "provizyon tamamlanınca
# elle hiçbir adım yok" ilkesiyle (ADR-0001 Bölüm 3) tam uyumludur.
# =============================================================================
_catalogInfoYaml = """
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: tenant-${teamName}-${environment}
  title: ${teamName} (${environment})
  description: Tenant namespace — quotaTier=${quotaTier}, networkTier=${networkTier}
  annotations:
    backstage.io/kubernetes-namespace: ${nsName}
  tags:
    - tenant
    - ${environment}
spec:
  type: tenant-namespace
  lifecycle: production
  owner: team-${teamName}
  system: internal-developer-platform
"""

catalogInfoConfigMap = {
    apiVersion = "v1"
    kind = "ConfigMap"
    metadata = {
        name = "catalog-info"
        namespace = nsName
        annotations = _resAnno("catalog-info")
        labels = {**labels, "backstage.io/catalog-info" = "true"}
    }
    data = {"catalog-info.yaml" = _catalogInfoYaml}
}

# =============================================================================
# 9. Grafana dashboard — otomatik klasör + temel dashboard (Faz 9)
#
# kube-prometheus-stack'in Grafana sidecar'ı (control-plane/observability/
# values.yaml: sidecar.dashboards, searchNamespace=ALL) `grafana_dashboard:
# "1"` etiketli ConfigMap'leri TÜM namespace'lerde tarar ve `grafana_folder`
# annotation'ındaki klasöre yükler — bu yüzden ayrı bir GrafanaDashboard CRD
# (grafana-operator) GEREKMEZ, composition sadece bir ConfigMap üretir.
#
# Panel seçimi: cadvisor/kube-state-metrics'ten namespace bazlı CPU/bellek/ağ
# (her tenant için HER ZAMAN veri var) + CNPG (Postgres) panelleri — bu
# panellerin sorguları `namespace="${nsName}"` ile sınırlı olduğundan, o
# tenant'ta henüz bir XPostgreSQLInstance YOKSA panel "No data" gösterir
# (Postgres varsa otomatik veri akar) — Grafana'nın panel bazlı koşullu
# gösterim desteği olmadığından "yoksa panel gizlensin" YERİNE bu daha basit
# ve conventions.md ile tutarlı bir çözüm olarak seçildi.
# =============================================================================
_dashboardJson = """{
  "title": "Tenant: ${teamName} (${environment})",
  "uid": "tenant-${teamName}-${environment}",
  "tags": ["tenant", "${teamName}", "${environment}"],
  "timezone": "utc",
  "schemaVersion": 39,
  "panels": [
    {
      "id": 1, "title": "CPU kullanımı (namespace)", "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "targets": [{"expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\\\"${nsName}\\\", container!=\\\"\\\"}[5m]))", "legendFormat": "cpu"}],
      "fieldConfig": {"defaults": {"unit": "short"}}
    },
    {
      "id": 2, "title": "Bellek kullanımı (namespace)", "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
      "targets": [{"expr": "sum(container_memory_working_set_bytes{namespace=\\\"${nsName}\\\", container!=\\\"\\\"})", "legendFormat": "memory"}],
      "fieldConfig": {"defaults": {"unit": "bytes"}}
    },
    {
      "id": 3, "title": "Ağ trafiği (namespace, in/out)", "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
      "targets": [
        {"expr": "sum(rate(container_network_receive_bytes_total{namespace=\\\"${nsName}\\\"}[5m]))", "legendFormat": "receive"},
        {"expr": "sum(rate(container_network_transmit_bytes_total{namespace=\\\"${nsName}\\\"}[5m]))", "legendFormat": "transmit"}
      ],
      "fieldConfig": {"defaults": {"unit": "Bps"}}
    },
    {
      "id": 4, "title": "Pod sayısı / kota", "type": "stat",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
      "targets": [{"expr": "count(kube_pod_info{namespace=\\\"${nsName}\\\"})", "legendFormat": "pods"}]
    },
    {
      "id": 5, "title": "PostgreSQL — bağlantılar (CNPG, varsa)", "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 16},
      "targets": [{"expr": "sum(cnpg_backends_total{namespace=\\\"${nsName}\\\"})", "legendFormat": "connections"}]
    },
    {
      "id": 6, "title": "PostgreSQL — replikasyon gecikmesi (CNPG, varsa)", "type": "timeseries",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 16},
      "targets": [{"expr": "cnpg_pg_replication_lag{namespace=\\\"${nsName}\\\"}", "legendFormat": "{{pod}}"}],
      "fieldConfig": {"defaults": {"unit": "s"}}
    }
  ],
  "time": {"from": "now-6h", "to": "now"},
  "refresh": "1m"
}
"""

grafanaDashboardConfigMap = {
    apiVersion = "v1"
    kind = "ConfigMap"
    metadata = {
        name = "tenant-dashboard"
        namespace = nsName
        annotations = {**_resAnno("grafana-dashboard"), "grafana_folder" = "Tenants/${teamName}-${environment}"}
        labels = {**labels, "grafana_dashboard" = "1"}
    }
    data = {"tenant-${teamName}-${environment}.json" = _dashboardJson}
}

items = [
    namespace
    role
    roleBinding
    resourceQuota
    limitRange
    defaultDenyPolicy
    tierNetworkPolicy
    serviceAccount
    vaultBootstrapJob
    vaultCaSecretStore
    vaultCaExternalSecret
    issuer
    certManagerServiceAccount
    certManagerTokenRequestRole
    certManagerTokenRequestRoleBinding
    esoServiceAccount
    esoTokenRequestRole
    esoTokenRequestRoleBinding
    catalogInfoConfigMap
    grafanaDashboardConfigMap
]
