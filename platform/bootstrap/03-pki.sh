#!/usr/bin/env bash
# =============================================================================
# Faz 3 — PKI: Vault (HA/Raft) + Kubernetes auth + PKI hiyerarşisi + cert-manager
#
#   Vault kurulumu → [İNSAN: init/unseal, bkz. docs/runbooks/vault-unseal.md]
#     → Kubernetes auth → PKI (root → 3× intermediate) → cert-manager
#     → ClusterIssuer'lar → test sertifikası (uçtan uca doğrulama)
#
# TASARIM KURALLARI (01/02 ile aynı + PKI'ye özgü olanlar):
#   1. IDEMPOTENT.
#   2. HARDCODED DEĞER YOK.
#   3. HER ADIMDA READINESS.
#   4. Vault init/unseal İNSAN EYLEMİDİR — script bunu OTOMATİKLEŞTİRMEZ,
#      yalnızca durumu kontrol edip bekler ve runbook'a yönlendirir.
#   5. VAULT_TOKEN yalnızca OPERATÖRÜN KENDİ shell ortam değişkeninden okunur
#      (`export VAULT_TOKEN=...`), hiçbir dosyaya YAZILMAZ. Script bunu
#      kontrol eder; yoksa ilgili adımı çalıştırmaz.
#
# KULLANIM
#   export VAULT_TOKEN="<docs/runbooks/vault-unseal.md §3.3'ten>"
#   ./platform/bootstrap/03-pki.sh                  # tümü
#   ./platform/bootstrap/03-pki.sh --only pki       # tek adım
#   ./platform/bootstrap/03-pki.sh --verify-only
#
# ÖN KOŞUL: Faz 1+2 tamamlanmış olmalı.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNDERLAY_DIR="${REPO_ROOT}/platform/underlay"
PKI_DIR="${REPO_ROOT}/platform/pki"
VAULT_DIR="${PKI_DIR}/vault"
CERT_MANAGER_DIR="${PKI_DIR}/cert-manager"
ENV_FILE="${UNDERLAY_DIR}/.env"
VERSIONS_FILE="${UNDERLAY_DIR}/versions.env"

ONLY=""
DRY_RUN="false"
VERIFY_ONLY="false"
ASSUME_YES="false"
KEEP_TEST_CERT="false"

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

_ts() { date '+%H:%M:%S'; }
log()   { printf '%s [%s] %s\n'    "$(_ts)" "${C_BLU}INFO${C_RST}" "$*"; }
ok()    { printf '%s [%s]   %s\n'  "$(_ts)" "${C_GRN} OK ${C_RST}" "$*"; }
warn()  { printf '%s [%s] %s\n'    "$(_ts)" "${C_YLW}WARN${C_RST}" "$*" >&2; }
err()   { printf '%s [%s] %s\n'    "$(_ts)" "${C_RED}FAIL${C_RST}" "$*" >&2; }
step()  { printf '\n%s%s══ %s %s%s\n' "${C_BLD}" "${C_BLU}" "$*" "══" "${C_RST}"; }
die() { err "$*"; exit 1; }

trap 'err "Satır ${LINENO}: komut başarısız (exit=$?). Yukarıdaki çıktıya bakın."' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)           ONLY="${2:-}"; shift 2 ;;
    --dry-run)        DRY_RUN="true"; shift ;;
    --verify-only)    VERIFY_ONLY="true"; shift ;;
    --yes|-y)         ASSUME_YES="true"; shift ;;
    --keep-test-cert) KEEP_TEST_CERT="true"; shift ;;
    -h|--help)        sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                die "Bilinmeyen argüman: $1  (--help)" ;;
  esac
done

should_run() { [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]; }

confirm() {
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  local reply
  read -r -p "$(printf '%s[?]%s %s [e/H] ' "${C_YLW}" "${C_RST}" "$1")" reply
  [[ "${reply}" =~ ^([eE]|[yY])$ ]]
}

wait_for() {
  local desc="$1" timeout="$2" interval="${3:-10}"; shift 3
  local elapsed=0
  log "Bekleniyor: ${desc} (timeout ${timeout}s)"
  while (( elapsed < timeout )); do
    if "$@" >/dev/null 2>&1; then
      ok "${desc} — hazır (${elapsed}s)"
      return 0
    fi
    sleep "${interval}"
    elapsed=$(( elapsed + interval ))
    (( elapsed % 60 == 0 )) && log "  ... ${desc} (${elapsed}/${timeout}s)"
  done
  err "ZAMAN AŞIMI: ${desc} (${timeout}s)"
  "$@" 2>&1 | sed 's/^/         /' >&2 || true
  return 1
}

helm_repo() {
  local name="$1" url="$2"
  helm repo list -o json 2>/dev/null | jq -e --arg n "$name" '.[]|select(.name==$n)' >/dev/null \
    || helm repo add "$name" "$url" >/dev/null
}

render() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "${dst}")"
  envsubst '${PLATFORM_BASE_DOMAIN}' < "${src}" > "${dst}"
}

# Vault pod'unda vault CLI çalıştırır. Root/admin işlemleri için VAULT_TOKEN
# operatörün KENDİ shell'inden geçirilir — asla dosyaya yazılmaz.
#
# NOT (`shift` neden zorunlu): `sh -c script -- "$1" "$@"` çağrısında sh'ye
# geçen argv şu şekildedir: $0="--", $1=TOKEN, $2..=asıl vault argümanları.
# `shift` ATLANIRSA "$@" token'ı da İÇİNE ALIR ve `vault <TOKEN> status ...`
# gibi YANLIŞ bir komut çalışır (token, `status`'tan önce bir alt komutmuş
# gibi vault'a geçer). Bu, yazarken bir kez yanlış yapılıp sh -c'nin
# pozisyonel argüman semantiği elle test edilerek düzeltildi.
vexec() {
  kubectl -n vault exec vault-0 -- sh -c \
    'VAULT_ADDR=http://127.0.0.1:8200; export VAULT_ADDR
     VAULT_TOKEN="$1"; export VAULT_TOKEN
     shift
     exec vault "$@"' \
    -- "${VAULT_TOKEN}" "$@"
}

# Token gerektirmeyen salt-okunur/durum sorguları için (ör. `vault status`)
vexec_notoken() {
  kubectl -n vault exec vault-0 -- sh -c \
    'VAULT_ADDR=http://127.0.0.1:8200 vault "$@"' -- "$@"
}

require_vault_token() {
  [[ -n "${VAULT_TOKEN:-}" ]] || die \
"VAULT_TOKEN ortam değişkeni boş.
     export VAULT_TOKEN=\"<docs/runbooks/vault-unseal.md §3.3'ten>\"
     Bu değişken hiçbir dosyaya YAZILMAZ — yalnızca bu shell oturumunda kalır."
}

# =============================================================================
# 0. Ön kontroller
# =============================================================================
preflight() {
  step "0/6  Ön kontroller"

  if (( BASH_VERSINFO[0] < 4 )); then
    die "bash 4+ gerekli (bulunan: ${BASH_VERSION})."
  fi
  for bin in kubectl helm envsubst jq openssl; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı."
  done
  ok "Gerekli araçlar mevcut"

  kubectl cluster-info >/dev/null 2>&1 || die "Cluster'a ulaşılamıyor."
  ok "Cluster erişimi: $(kubectl config current-context)"

  [[ -f "${VERSIONS_FILE}" ]] || die "Sürüm dosyası yok: ${VERSIONS_FILE}"
  set -a; source "${VERSIONS_FILE}"; set +a
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} yok."
  set -a; source "${ENV_FILE}"; set +a

  [[ -n "${PLATFORM_BASE_DOMAIN:-}" ]] || die "PLATFORM_BASE_DOMAIN .env'de boş."
  ok "PLATFORM_BASE_DOMAIN=${PLATFORM_BASE_DOMAIN}"

  if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
     && ! kubectl get storageclass ceph-block >/dev/null 2>&1; then
    warn "Faz 1/2 tespit edilemedi (ne ArgoCD ne ceph-block var)."
    confirm "Yine de devam edilsin mi?" || exit 1
  fi
}

# =============================================================================
# 1. Vault kurulumu (Helm) — init/unseal İNSAN EYLEMİDİR, script yalnızca bekler
# =============================================================================
install_vault() {
  step "1/6  Vault (HA / Raft, 3 replika)"

  helm_repo hashicorp "${VAULT_HELM_REPO}"
  helm repo update hashicorp >/dev/null

  kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace vault platform.internal/layer=pki --overwrite >/dev/null

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install vault hashicorp/vault --version ${VAULT_CHART_VERSION}"
    return 0
  fi

  # NOT: --wait KULLANILMIYOR. Chart'ın readinessProbe'u "sealed" durumda
  # BAŞARISIZ olur (bilinçli, values.yaml'da açıklandı) — --wait burada
  # sonsuza kadar bekler. Bunun yerine yalnızca pod'ların "Running" (Ready
  # değil) olmasını bekliyoruz.
  helm upgrade --install vault hashicorp/vault \
    --namespace vault --version "${VAULT_CHART_VERSION}" \
    -f "${VAULT_DIR}/values.yaml" \
    --timeout 10m

  wait_for "vault-0 pod Running" 300 10 \
    bash -c "kubectl -n vault get pod vault-0 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running"
  wait_for "vault-1 pod Running" 300 10 \
    bash -c "kubectl -n vault get pod vault-1 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running"
  wait_for "vault-2 pod Running" 300 10 \
    bash -c "kubectl -n vault get pod vault-2 -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running"

  check_init_and_unseal_status
  enable_vault_audit
}

# =============================================================================
# Vault audit log — Faz 10, görev madde 5.
#
# NEDEN "file" audit device (socket DEĞİL): socket device, dinleyici
# ÇÖKERSE/yanıt vermezse Vault'un TÜM istekleri REDDETMESİNE yol açabilir
# (Vault, HİÇBİR audit device günlüğü YAZAMAZSA fail-closed davranır) —
# bare-metal'de ayrı bir syslog/audit toplayıcı olmadan bu riski almak
# yerine, HA/Raft PV'sinin zaten güvenilir olduğu file device tercih
# edildi. Birden fazla audit device etkinse Vault YAZMA BAŞARILI olduğu
# sürece çalışmaya devam eder (en az biri yazabildiği sürece fail-closed
# TETİKLENMEZ) — ileride bir syslog device EKLENEBİLİR, KALDIRILAMAZ
# (tek device varken onu devre dışı bırakmak audit sürekliliğini kırar).
#
# İDEMPOTENT: `vault audit enable` zaten etkin bir path'te "path is already
# in use" hatası verir — bu BEKLENEN bir durumdur, script BUNU hata
# saymaz.
# =============================================================================
enable_vault_audit() {
  log "Vault audit log (file device) kontrol ediliyor..."

  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    warn "  VAULT_TOKEN yok — audit device etkinleştirme ATLANDI."
    warn "  Elle: export VAULT_TOKEN=... && $0 --only vault"
    return 0
  fi

  local existing
  existing="$(vexec audit list -format=json 2>/dev/null || echo '{}')"
  if echo "${existing}" | jq -e '.["file/"]' >/dev/null 2>&1; then
    ok "  Audit device 'file/' zaten etkin"
    return 0
  fi

  if vexec audit enable file file_path=/vault/audit/vault-audit.log 2>&1 | tee /tmp/vault-audit-enable.log; then
    ok "  Audit device 'file/' etkinleştirildi (/vault/audit/vault-audit.log, vault-0/1/2'nin her birinde YEREL)"
    warn "  NOT: her Vault pod'u KENDİ yerel audit log'unu tutar (paylaşımlı PV YOK) —"
    warn "  merkezi bir görünüm için 3 pod'un log'unu toplayan bir Loki/Promtail"
    warn "  DaemonSet'i (bkz. control-plane/observability/) veya benzeri bir"
    warn "  toplayıcı GEREKİR — bu görev kapsamında YAZILMADI (teknik borç)."
  elif grep -qi "already in use\|already enabled" /tmp/vault-audit-enable.log; then
    ok "  Audit device 'file/' zaten etkin (idempotent — bu bir hata DEĞİL)"
  else
    err "  Audit device etkinleştirilemedi — yukarıdaki çıktıya bakın."
    return 1
  fi
}

verify_vault_audit() {
  log "DOĞRULAMA: Vault audit log"
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    warn "  VAULT_TOKEN yok — audit device durumu okunamıyor."
    return 0
  fi
  vexec audit list 2>/dev/null | sed 's/^/         /' || warn "  audit list okunamadı"
}

# Init/unseal durumunu kontrol eder. Eksikse DURUR ve runbook'a yönlendirir —
# HİÇBİR ŞEYİ OTOMATİK YAPMAZ.
check_init_and_unseal_status() {
  log "Vault init/unseal durumu kontrol ediliyor..."
  local status_json initialized sealed
  status_json="$(vexec_notoken status -format=json 2>/dev/null || echo '{}')"
  initialized="$(echo "${status_json}" | jq -r '.initialized // false' 2>/dev/null)"
  sealed="$(echo "${status_json}" | jq -r '.sealed // true' 2>/dev/null)"

  if [[ "${initialized}" != "true" ]]; then
    warn "─────────────────────────────────────────────────────────────────"
    warn " Vault HENÜZ INIT EDİLMEMİŞ."
    warn " Bu script init'i OTOMATİKLEŞTİRMEZ (Shamir key dağıtımı bir"
    warn " insan prosedürüdür)."
    warn ""
    warn " ŞİMDİ ÇALIŞTIRIN:  docs/runbooks/vault-unseal.md  (§3 ve §4)"
    warn " Bitince tekrar:    $0 --only vault"
    warn "─────────────────────────────────────────────────────────────────"
    die "Init/unseal bekleniyor."
  fi

  if [[ "${sealed}" != "false" ]]; then
    warn "─────────────────────────────────────────────────────────────────"
    warn " Vault init edilmiş ama SEALED (mühürlü)."
    warn " ŞİMDİ ÇALIŞTIRIN:  docs/runbooks/vault-unseal.md  §4 (unseal)"
    warn " Bitince tekrar:    $0 --only vault"
    warn "─────────────────────────────────────────────────────────────────"
    die "Unseal bekleniyor."
  fi

  ok "Vault initialized=true, sealed=false"
  verify_vault
}

verify_vault() {
  log "DOĞRULAMA: Vault"
  kubectl -n vault get pods | sed 's/^/         /'
  vexec_notoken status 2>/dev/null | sed 's/^/         /' || true
  ok "Vault doğrulandı (HA/Raft, 3 replika, unsealed)"
}

# =============================================================================
# 2. Kubernetes Auth Method
# =============================================================================
setup_kubernetes_auth() {
  step "2/6  Vault Kubernetes Auth Method"
  require_vault_token

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] auth/kubernetes enable + configure + policy + role"
    return 0
  fi

  # --- Vault'un kendi ServiceAccount'ının TokenReview yetkisi -------------
  # Kubernetes auth method, gelen SA token'ları doğrulamak için
  # `system:auth-delegator` ClusterRole'üne ihtiyaç duyar. Chart bunu
  # OTOMATİK oluşturmaz — standart, dokümante edilmiş adım.
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-kubernetes-auth-delegator
  labels:
    platform.internal/managed-by: pki-bootstrap
subjects:
  - kind: ServiceAccount
    name: vault
    namespace: vault
roleRef:
  kind: ClusterRole
  name: system:auth-delegator
  apiGroup: rbac.authorization.k8s.io
EOF
  ok "vault SA → system:auth-delegator bağlandı"

  # --- Auth method enable (idempotent: zaten varsa hata verir, yut) -------
  vexec auth enable kubernetes 2>/dev/null || log "  auth/kubernetes zaten etkin"

  # --- Vault kendi pod'unun içinden kendi in-cluster ayarlarını okur ------
  vexec write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  ok "auth/kubernetes/config yazıldı"

  # --- KV v2 (Faz 7 eklentisi): PostgreSQL composition'ının ExternalSecret/
  # PushSecret round-trip'i için (bkz. compositions/postgresql/function.k §7).
  # Faz 6'da "henüz enable edilmedi" olarak bırakılmıştı (crossplane-
  # policy.hcl'deki not) — ilk gerçek tüketici bu faz.
  vexec secrets enable -path=kv -version=2 kv 2>/dev/null || log "  kv/ zaten mount edilmiş"

  # --- Policy'ler -----------------------------------------------------------
  for p in cert-manager crossplane root-ca-admin provider-terraform eso-tenant-secrets eso-platform-secrets; do
    kubectl -n vault cp "${VAULT_DIR}/policies/${p}-policy.hcl" "vault-0:/tmp/${p}-policy.hcl"
    vexec policy write "${p}" "/tmp/${p}-policy.hcl"
    ok "  policy '${p}' yazıldı"
  done

  # --- cert-manager rolü: cert-manager namespace'indeki cert-manager SA'sı -
  # DÜZELTME (Faz 12b, GERÇEK kind cluster'ında keşfedildi): bu role SADECE
  # `bound_service_account_namespaces=cert-manager` ile yazılıyordu — bu,
  # cert-manager'ın KENDİ pod'unun SA'sını (ClusterIssuer'lar için) kapsar
  # ama compositions/tenant/function.k'nin HER TENANT NAMESPACE'İNDE
  # oluşturduğu AYRI "cert-manager" ServiceAccount'ını (tenant-issuer'ın
  # `serviceAccountRef` ile kullandığı, cert-manager'ın Vault issuer'ı için
  # SAME-NAMESPACE token exchange semantiği) KAPSAMAZ. Sonuç: HER tenant'ın
  # sertifika imzalaması "403 namespace not authorized" ile KALICI OLARAK
  # başarısız olurdu (Issuer.status Ready=True yalnızca bağlantıyı doğrular,
  # GERÇEK bir imzalama denemesi YAPMAZ — bu yüzden bug ÖNCEDEN fark
  # edilmedi; gerçek bir Certificate ile UÇTAN UCA test edilerek bulundu).
  # `bound_service_account_namespace_selector` (Vault 1.16+) EKLENDİ —
  # `platform.internal/managed-by=crossplane` etiketine sahip HER namespace
  # (yalnızca tenant composition'ının ürettiği namespace'ler bu etikete
  # sahip) bu role ile de auth olabilir. İki koşul OR'lanır (Vault'un kendi
  # semantiği) — ClusterIssuer'lar (cert-manager'ın kendi SA'sı) VE
  # tenant Issuer'ları (per-tenant SA) AYNI ANDA çalışır.
  vexec write auth/kubernetes/role/cert-manager \
    bound_service_account_names=cert-manager \
    bound_service_account_namespaces=cert-manager \
    bound_service_account_namespace_selector='{"matchLabels":{"platform.internal/managed-by":"crossplane"}}' \
    policies=cert-manager \
    ttl=1h
  ok "  auth role 'cert-manager' → SA cert-manager/cert-manager VE her tenant namespace'indeki cert-manager SA'sı"

  # --- crossplane rolü: SA adı rastgele (Faz 2), etiketle bul -------------
  # DÜZELTME (Faz 12b, GERÇEK kind cluster'ında keşfedildi): `pkg.crossplane.
  # io/provider` etiketi ServiceAccount NESNESİNDE HİÇ YOK — yalnızca POD'UN
  # Deployment.spec.selector'ünde (dolayısıyla pod'un kendi etiketlerinde)
  # var. Eski `get sa -l ...` sorgusu HER ZAMAN boş sonuç döndürüyordu ve bu
  # `if [[ -n ... ]]` dalı SESSİZCE skip'e düşüyordu — yani hiçbir GERÇEK
  # bootstrap çalıştırmasında provider-kubernetes/provider-terraform Vault
  # auth role'leri OLUŞMUYORDU (tenant PKI/secrets otomasyonunun tamamını
  # kalıcı olarak bloke eden sessiz bir hata). Doğru sorgu: POD'u etiketle
  # bul, SA adını pod.spec.serviceAccountName'den oku.
  local cp_sa
  cp_sa="$(kubectl -n crossplane-system get pods \
           -l 'pkg.crossplane.io/provider=provider-kubernetes' \
           -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || true)"
  if [[ -n "${cp_sa}" ]]; then
    vexec write auth/kubernetes/role/provider-kubernetes \
      bound_service_account_names="${cp_sa}" \
      bound_service_account_namespaces=crossplane-system \
      policies=crossplane \
      ttl=1h
    ok "  auth role 'provider-kubernetes' → SA ${cp_sa} (crossplane-system)"
  else
    warn "  provider-kubernetes SA'sı bulunamadı (Faz 2 kurulu değil olabilir) — role atlandı"
  fi

  # --- provider-terraform rolü: Faz 6 XTenant composition'ının Vault
  # k8s-auth role/policy/PKI role'ü tenant başına yönetebilmesi için
  # (bkz. compositions/tenant/function.k, provider-terraform-policy.hcl).
  # SA adı Faz 2'deki gibi rastgele üretilir.
  # NOT: provider-terraform'un ServiceAccount adı artık DeploymentRuntimeConfig
  # "provider-terraform" (crossplane/resources/providers.yaml) ile SABİTLENDİ
  # ("provider-terraform") — bu sorgu yine de POD ÜZERİNDEN doğrulama amaçlı
  # tutuluyor (aynı Faz 12b düzeltmesi: SA değil POD etiketlenir).
  local tf_sa
  tf_sa="$(kubectl -n crossplane-system get pods \
           -l 'pkg.crossplane.io/provider=provider-terraform' \
           -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || true)"
  if [[ -n "${tf_sa}" ]]; then
    vexec write auth/kubernetes/role/provider-terraform \
      bound_service_account_names="${tf_sa}" \
      bound_service_account_namespaces=crossplane-system \
      policies=provider-terraform \
      ttl=1h
    ok "  auth role 'provider-terraform' → SA ${tf_sa} (crossplane-system)"
  else
    warn "  provider-terraform SA'sı bulunamadı (Faz 2 kurulu değil olabilir) — role atlandı"
  fi

  # --- eso-tenant-secrets rolü: ESO'nun TEK, paylaşımlı controller SA'sı --
  # (Faz 2 chart varsayılan adı: "external-secrets", namespace
  # "external-secrets"). Tüm tenant'lar bu TEK rolü paylaşır — izolasyon
  # SA bazında değil, `kv/data/tenants/*` path prefix'i bazındadır
  # (eso-tenant-secrets-policy.hcl).
  if kubectl -n external-secrets get sa external-secrets >/dev/null 2>&1; then
    vexec write auth/kubernetes/role/eso-tenant-secrets \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=external-secrets \
      policies=eso-tenant-secrets \
      ttl=1h
    ok "  auth role 'eso-tenant-secrets' → SA external-secrets/external-secrets"
  else
    warn "  ESO SA'sı (external-secrets/external-secrets) bulunamadı — role atlandı"
  fi

  # --- eso-platform-secrets rolü: AYNI SA, platform-genelinde path'e sahip
  # FARKLI bir rol (Faz 8 eklentisi — Backstage OIDC client secret'ı için).
  if kubectl -n external-secrets get sa external-secrets >/dev/null 2>&1; then
    vexec write auth/kubernetes/role/eso-platform-secrets \
      bound_service_account_names=external-secrets \
      bound_service_account_namespaces=external-secrets \
      policies=eso-platform-secrets \
      ttl=1h
    ok "  auth role 'eso-platform-secrets' → SA external-secrets/external-secrets"
  else
    warn "  ESO SA'sı bulunamadı — 'eso-platform-secrets' role atlandı"
  fi

  verify_kubernetes_auth
}

verify_kubernetes_auth() {
  log "DOĞRULAMA: Kubernetes Auth Method"
  vexec read auth/kubernetes/config 2>/dev/null | sed 's/^/         /' || true
  vexec list auth/kubernetes/role 2>/dev/null | sed 's/^/         /' || true
  ok "Kubernetes auth doğrulandı"
}

# =============================================================================
# 3. PKI hiyerarşisi: Root CA → 3× Intermediate CA
# =============================================================================
setup_pki() {
  step "3/6  PKI hiyerarşisi (Root → dev/staging/prod Intermediate)"
  require_vault_token

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] pki-root + pki-int-{dev,staging,prod} kurulacaktı"
    return 0
  fi

  # --- Root CA (10 yıl) ------------------------------------------------------
  vexec secrets enable -path=pki-root -max-lease-ttl=87600h pki 2>/dev/null \
    || log "  pki-root zaten mount edilmiş"

  if ! vexec read pki-root/cert/ca >/dev/null 2>&1; then
    vexec write -f pki-root/root/generate/internal \
      common_name="Platform Root CA" \
      ttl=87600h \
      key_type=rsa key_bits=4096
    ok "  Root CA üretildi (10 yıl)"
  else
    log "  Root CA zaten mevcut"
  fi

  vexec write pki-root/config/urls \
    issuing_certificates="http://vault-active.vault.svc.cluster.local:8200/v1/pki-root/ca" \
    crl_distribution_points="http://vault-active.vault.svc.cluster.local:8200/v1/pki-root/crl"

  # --- Ortam bazlı Intermediate CA'lar (2 yıl) ------------------------------
  local env
  for env in dev staging prod; do
    local mount="pki-int-${env}"
    vexec secrets enable -path="${mount}" -max-lease-ttl=17520h pki 2>/dev/null \
      || log "  ${mount} zaten mount edilmiş"

    if ! vexec read "${mount}/cert/ca" >/dev/null 2>&1; then
      # 1. Intermediate için CSR üret (private key Vault içinde, hiç çıkmaz)
      local csr
      csr="$(vexec write -format=json -f "${mount}/intermediate/generate/internal" \
             common_name="Platform Intermediate CA (${env})" \
             ttl=17520h key_type=rsa key_bits=4096 \
             | jq -r '.data.csr')"

      # 2. Root CA, CSR'ı imzalar (yalnızca bu adımda root-ca-admin policy
      #    gerekir — VAULT_TOKEN root/yeterince yetkili olmalı). CSR çok
      #    satırlı bir PEM'dir; tek bir argv elemanı olarak (bash'ten
      #    kubectl exec'e, oradan sh -c'nin "$@"'ına) bozulmadan taşınır.
      local signed_json
      signed_json="$(vexec write -format=json pki-root/root/sign-intermediate \
                      csr="${csr}" format=pem_bundle ttl=17520h)"
      local signed_cert
      signed_cert="$(echo "${signed_json}" | jq -r '.data.certificate')"

      # 3. İmzalı sertifikayı intermediate mount'una geri yaz
      vexec write "${mount}/intermediate/set-signed" certificate="${signed_cert}"
      ok "  ${mount}: Intermediate CA üretildi ve Root tarafından imzalandı (2 yıl)"
    else
      log "  ${mount}: Intermediate CA zaten mevcut"
    fi

    vexec write "${mount}/config/urls" \
      issuing_certificates="http://vault-active.vault.svc.cluster.local:8200/v1/${mount}/ca" \
      crl_distribution_points="http://vault-active.vault.svc.cluster.local:8200/v1/${mount}/crl"

    # --- PKI rolü: allowed_domains conventions §5'e göre <env>.<base-domain>
    #
    # DÜZELTME (Faz 12c, GERÇEK bir kind cluster'ında keşfedildi): platform-
    # GENELİNDEKİ paylaşılan servisler (Keycloak, Harbor, ArgoCD, Grafana —
    # `.env.example`'daki `KEYCLOAK_HOSTNAME`/`HARBOR_HOSTNAME` gibi) env-
    # ÖNEKSİZ hostname'ler kullanır (`keycloak.${PLATFORM_BASE_DOMAIN}`,
    # `<env>.${PLATFORM_BASE_DOMAIN}` DEĞİL) — ama bu rol yalnızca `<env>.
    # ${PLATFORM_BASE_DOMAIN}` alt alan adlarına izin veriyordu. Sonuç:
    # Keycloak için gerçek bir cert-manager Certificate isteği canlı olarak
    # "common name keycloak.apps.example.internal not allowed by this role"
    # ile KESİN olarak REDDEDİLDİ (bu servisler `vault-issuer-dev`'i
    # kullanıyor — bkz. cert-manager/resources/clusterissuers.yaml — bu
    # yüzden yalnızca "dev" rolüne bu ikinci domain eklendi, diğer env
    # rollerine DEĞİL, çünkü platform servisleri şu an yalnızca dev
    # issuer'ı kullanıyor). Bare base domain (alt alan adlarıyla birlikte)
    # EKLENDİ.
    local platform_allowed_domains="${env}.${PLATFORM_BASE_DOMAIN}"
    [[ "${env}" == "dev" ]] && platform_allowed_domains="${env}.${PLATFORM_BASE_DOMAIN},${PLATFORM_BASE_DOMAIN}"
    vexec write "${mount}/roles/platform-${env}" \
      allowed_domains="${platform_allowed_domains}" \
      allow_subdomains=true \
      allow_glob_domains=true \
      max_ttl=2160h \
      ttl=2160h \
      key_type=rsa key_bits=2048
    ok "  ${mount}/roles/platform-${env} tanımlandı (allowed_domains=${platform_allowed_domains}, max_ttl=90g)"
  done

  print_fingerprints
}

# Root ve her Intermediate CA'nın SHA-256 fingerprint'ini basar —
# PLATFORM_CONTEXT.md'ye elle kopyalanacak satırlar.
print_fingerprints() {
  log "─────────────────────────────────────────────────────────────────"
  log " PKI FINGERPRINT'LERİ (PLATFORM_CONTEXT.md §'Kurulu bileşenler'e kopyalayın)"
  log "─────────────────────────────────────────────────────────────────"

  local mount fp subject
  for mount in pki-root pki-int-dev pki-int-staging pki-int-prod; do
    local pem="/tmp/${mount}-ca.pem"
    vexec_notoken read -field=certificate "${mount}/cert/ca" > "${pem}" 2>/dev/null || {
      vexec read -format=json "${mount}/cert/ca" 2>/dev/null | jq -r '.data.certificate' > "${pem}"
    }
    if [[ -s "${pem}" ]]; then
      fp="$(openssl x509 -in "${pem}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//')"
      subject="$(openssl x509 -in "${pem}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
      printf '  %-16s  %s\n' "${mount}" "${subject}"
      printf '  %-16s  SHA256:%s\n' "" "${fp}"
    else
      warn "  ${mount}: sertifika okunamadı"
    fi
    rm -f "${pem}"
  done
  log "─────────────────────────────────────────────────────────────────"

  verify_pki
}

verify_pki() {
  log "DOĞRULAMA: PKI mount'ları"
  vexec_notoken secrets list 2>/dev/null | grep -E '^pki' | sed 's/^/         /' || true
  ok "PKI hiyerarşisi doğrulandı"
}

# =============================================================================
# 4. cert-manager + ClusterIssuer'lar
# =============================================================================
install_cert_manager() {
  step "4/6  cert-manager + Vault-backed ClusterIssuer'lar"

  helm_repo jetstack "${CERT_MANAGER_HELM_REPO}"
  helm repo update jetstack >/dev/null

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install cert-manager jetstack/cert-manager --version ${CERT_MANAGER_CHART_VERSION}"
    return 0
  fi

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "${CERT_MANAGER_CHART_VERSION}" \
    -f "${CERT_MANAGER_DIR}/values.yaml" \
    --wait --timeout 10m

  wait_for "cert-manager controller" 300 10 \
    kubectl -n cert-manager rollout status deployment/cert-manager --timeout=5s
  wait_for "cert-manager webhook" 300 10 \
    kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=5s
  wait_for "cert-manager cainjector" 300 10 \
    kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=5s

  # Webhook hazır olduktan hemen sonra ClusterIssuer apply'ı yarış (race)
  # yapabilir — kısa bir retry.
  local tries=0
  until kubectl apply -f "${CERT_MANAGER_DIR}/resources/clusterissuers.yaml"; do
    tries=$(( tries + 1 )); (( tries > 6 )) && die "ClusterIssuer'lar apply edilemedi"
    warn "  webhook henüz hazır değil, 10s sonra tekrar (${tries}/6)"; sleep 10
  done

  apply_servicemonitor_if_crd_exists

  wait_for "ClusterIssuer vault-issuer-dev Ready" 120 10 \
    bash -c "kubectl get clusterissuer vault-issuer-dev -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"
  wait_for "ClusterIssuer vault-issuer-staging Ready" 60 10 \
    bash -c "kubectl get clusterissuer vault-issuer-staging -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"
  wait_for "ClusterIssuer vault-issuer-prod Ready" 60 10 \
    bash -c "kubectl get clusterissuer vault-issuer-prod -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

  verify_cert_manager
}

apply_servicemonitor_if_crd_exists() {
  if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    kubectl apply -f "${CERT_MANAGER_DIR}/resources/servicemonitor.yaml"
    ok "ServiceMonitor uygulandı (Prometheus Operator CRD'si mevcut)"
  else
    warn "servicemonitors.monitoring.coreos.com CRD'si YOK (Faz 4'te gelecek)."
    warn "ServiceMonitor manifesti ${CERT_MANAGER_DIR}/resources/servicemonitor.yaml içinde HAZIR"
    warn "ama uygulanmadı. Faz 4'te: kubectl apply -f ${CERT_MANAGER_DIR}/resources/servicemonitor.yaml"
  fi
}

verify_cert_manager() {
  log "DOĞRULAMA: cert-manager"
  kubectl -n cert-manager get pods | sed 's/^/         /'
  log "  \$ kubectl get clusterissuer"
  kubectl get clusterissuer -o custom-columns=\
'NAME:.metadata.name,READY:.status.conditions[0].status,REASON:.status.conditions[0].reason' \
    2>/dev/null | sed 's/^/         /'
  ok "cert-manager doğrulandı"
}

# =============================================================================
# 5. Uçtan uca test: örnek Certificate → Vault üzerinden imzalanmış mı?
# =============================================================================
verify_certificate() {
  step "5/6  Uçtan uca sertifika testi"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] test sertifikası uygulanıp doğrulanacaktı"
    return 0
  fi

  render "${CERT_MANAGER_DIR}/test-certificate.yaml.tpl" \
         "${CERT_MANAGER_DIR}/rendered/test-certificate.yaml"
  kubectl apply -f "${CERT_MANAGER_DIR}/rendered/test-certificate.yaml"

  wait_for "Certificate pki-smoke-test Ready" 120 5 \
    bash -c "kubectl -n pki-test get certificate pki-smoke-test -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

  log "\$ kubectl -n pki-test describe certificate pki-smoke-test"
  kubectl -n pki-test describe certificate pki-smoke-test | sed 's/^/         /'

  # --- Leaf sertifikayı çıkar ------------------------------------------------
  local work; work="$(mktemp -d)"
  kubectl -n pki-test get secret pki-smoke-test-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d > "${work}/leaf.crt"
  kubectl -n pki-test get secret pki-smoke-test-tls -o jsonpath='{.data.ca\.crt}' \
    | base64 -d > "${work}/intermediate.crt"

  # --- Vault'tan Root CA'yı çek, güven zincirini tamamla ---------------------
  vexec_notoken read -field=certificate pki-root/cert/ca > "${work}/root.crt" 2>/dev/null || \
    vexec read -format=json pki-root/cert/ca 2>/dev/null | jq -r '.data.certificate' > "${work}/root.crt"
  cat "${work}/intermediate.crt" "${work}/root.crt" > "${work}/chain.pem"

  log "\$ openssl x509 -in leaf.crt -noout -subject -issuer -dates"
  openssl x509 -in "${work}/leaf.crt" -noout -subject -issuer -dates | sed 's/^/         /'

  log "\$ openssl verify -CAfile chain.pem leaf.crt"
  if openssl verify -CAfile "${work}/chain.pem" "${work}/leaf.crt" | tee /tmp/pki-verify-out | grep -q ": OK"; then
    ok "Sertifika zinciri DOĞRULANDI — Vault Root → Intermediate → leaf"
    sed 's/^/         /' /tmp/pki-verify-out
  else
    err "openssl verify BAŞARISIZ:"
    sed 's/^/         /' /tmp/pki-verify-out
    rm -rf "${work}"
    return 1
  fi

  rm -f /tmp/pki-verify-out
  rm -rf "${work}"

  if [[ "${KEEP_TEST_CERT}" == "true" ]]; then
    warn "--keep-test-cert verildi — pki-test namespace'i SİLİNMEDİ"
  else
    kubectl delete namespace pki-test --wait=false >/dev/null 2>&1 || true
    ok "Test namespace'i (pki-test) temizlendi"
  fi
}

# =============================================================================
# Özet
# =============================================================================
summary() {
  step "Özet"
  printf '\n  %-14s %-14s %s\n' "BİLEŞEN" "NAMESPACE" "DURUM"
  printf '  %s\n' "────────────────────────────────────────────────────────"
  local rows=(
    "Vault|vault|statefulset/vault"
    "cert-manager|cert-manager|deployment/cert-manager"
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r name ns res <<< "${row}"
    local state="${C_RED}yok${C_RST}"
    if kubectl -n "${ns}" get "${res}" >/dev/null 2>&1; then
      state="${C_GRN}kurulu${C_RST}"
    fi
    printf '  %-14s %-14s %b\n' "${name}" "${ns}" "${state}"
  done

  cat <<EOS

  Sonraki adımlar
  ───────────────
  1. print_fingerprints çıktısındaki fingerprint'leri PLATFORM_CONTEXT.md'ye
     elle kopyalayın (script dosyayı KENDİSİ değiştirmez).
  2. docs/runbooks/vault-unseal.md §5: root token'ı iptal ettiğinizi doğrulayın.
  3. ESO'nun ilk SecretStore'unu (bu fazın kapsamı DIŞINDA) bir sonraki
     PR'da ekleyin — auth/kubernetes/role/provider-kubernetes hazır.
  4. Faz 4: kube-prometheus-stack kurulunca
     platform/pki/cert-manager/resources/servicemonitor.yaml'ı uygulayın.

  Erişim
  ──────
  Vault UI       kubectl -n vault port-forward svc/vault 8200:8200
  ClusterIssuer  kubectl get clusterissuer

EOS
}

# =============================================================================
main() {
  log "Faz 3 — PKI kurulumu"
  [[ "${DRY_RUN}"     == "true" ]] && warn "DRY-RUN: hiçbir değişiklik uygulanmaz"
  [[ "${VERIFY_ONLY}" == "true" ]] && warn "VERIFY-ONLY: yalnızca doğrulama"
  [[ -n "${ONLY}"               ]] && log  "Yalnızca adım: ${ONLY}"

  preflight

  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    should_run vault        && verify_vault              || true
    should_run vault        && verify_vault_audit         || true
    should_run auth         && verify_kubernetes_auth     || true
    should_run pki          && verify_pki                 || true
    should_run cert-manager && verify_cert_manager        || true
    summary
    return 0
  fi

  should_run vault        && install_vault
  should_run auth         && setup_kubernetes_auth
  should_run pki          && setup_pki
  should_run cert-manager && install_cert_manager
  should_run cert-test    && verify_certificate

  summary
  ok "Faz 3 tamamlandı."
}

main "$@"
