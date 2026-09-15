#!/usr/bin/env bash
# =============================================================================
# Faz 1 — Underlay kurulumu
#
#   Cilium → MetalLB → Rook-Ceph → Keycloak → Harbor → (ops.) default-deny
#
# TASARIM KURALLARI
#   1. IDEMPOTENT: her adım `helm upgrade --install` / `kubectl apply` kullanır.
#      Script kaç kez çalıştırılırsa çalıştırılsın sonuç aynıdır. Yarıda kesilen
#      bir kurulum, script tekrar çalıştırılarak kaldığı yerden devam eder.
#   2. HARDCODED DEĞER YOK: tüm IP, host ve parola .env'den gelir.
#      Eksik/boş zorunlu değişken → script BAŞLAMADAN durur (fail-fast).
#   3. HER ADIMDA READINESS: bir sonraki adıma, öncekinin sağlık kontrolü
#      geçmeden geçilmez. "apply et ve umut et" yok.
#   4. YIKICI İŞLEM ONAYI: disk silen tek adım (Ceph OSD) açık onay ister.
#
# KULLANIM
#   cp platform/underlay/.env.example platform/underlay/.env
#   $EDITOR platform/underlay/.env
#   ./platform/bootstrap/01-underlay.sh                 # tümü
#   ./platform/bootstrap/01-underlay.sh --only cilium   # tek adım
#   ./platform/bootstrap/01-underlay.sh --verify-only   # sadece doğrulama
#   ./platform/bootstrap/01-underlay.sh --dry-run       # render et, uygulama
#
# ÖN KOŞULLAR: bkz. platform/underlay/README.md
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNDERLAY_DIR="${REPO_ROOT}/platform/underlay"
CONTROL_PLANE_DIR="${REPO_ROOT}/platform/control-plane"
ENV_FILE="${UNDERLAY_DIR}/.env"
VERSIONS_FILE="${UNDERLAY_DIR}/versions.env"

ONLY=""
DRY_RUN="false"
VERIFY_ONLY="false"
ASSUME_YES="false"

# --- Renkli, zaman damgalı çıktı --------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

_ts() { date '+%H:%M:%S'; }
log()   { printf '%s [%s] %s\n'            "$(_ts)" "${C_BLU}INFO${C_RST}" "$*"; }
ok()    { printf '%s [%s]   %s\n'          "$(_ts)" "${C_GRN} OK ${C_RST}" "$*"; }
warn()  { printf '%s [%s] %s\n'            "$(_ts)" "${C_YLW}WARN${C_RST}" "$*" >&2; }
err()   { printf '%s [%s] %s\n'            "$(_ts)" "${C_RED}FAIL${C_RST}" "$*" >&2; }
step()  { printf '\n%s%s══ %s %s%s\n' "${C_BLD}" "${C_BLU}" "$*" "══" "${C_RST}"; }

die() { err "$*"; exit 1; }

# Hata anında hangi satırda patladığını göster — sessiz başarısızlık yok
trap 'err "Satır ${LINENO}: komut başarısız (exit=$?). Yukarıdaki çıktıya bakın."' ERR

# --- Argüman ayrıştırma -----------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)        ONLY="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --verify-only) VERIFY_ONLY="true"; shift ;;
    --yes|-y)      ASSUME_YES="true"; shift ;;
    -h|--help)     sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "Bilinmeyen argüman: $1  (--help)" ;;
  esac
done

should_run() { [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]; }

# =============================================================================
# 0. Ön kontroller
# =============================================================================
preflight() {
  step "0/7  Ön kontroller"

  # ${VAR,,} ve diğer bash 4 özellikleri kullanılıyor.
  # macOS'un varsayılan bash'i 3.2'dir — sessiz yanlış davranış yerine açık hata.
  if (( BASH_VERSINFO[0] < 4 )); then
    die "bash 4+ gerekli (bulunan: ${BASH_VERSION}).
     macOS:  brew install bash  →  /opt/homebrew/bin/bash $0"
  fi

  for bin in kubectl helm envsubst jq; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı. Kurun ve tekrar deneyin."
  done
  ok "Gerekli araçlar mevcut (kubectl, helm, envsubst, jq)"

  kubectl cluster-info >/dev/null 2>&1 \
    || die "Cluster'a ulaşılamıyor. KUBECONFIG doğru mu?"
  ok "Cluster erişimi: $(kubectl config current-context)"

  [[ -f "${VERSIONS_FILE}" ]] || die "Sürüm dosyası yok: ${VERSIONS_FILE}"
  # shellcheck disable=SC1090
  set -a; source "${VERSIONS_FILE}"; set +a
  ok "Sürümler yüklendi (Cilium ${CILIUM_CHART_VERSION}, Rook ${ROOK_CHART_VERSION})"

  if [[ ! -f "${ENV_FILE}" ]]; then
    die "${ENV_FILE} yok.
     Oluşturmak için:
       cp ${UNDERLAY_DIR}/.env.example ${ENV_FILE}
     sonra doldurun."
  fi
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a

  # --- Zorunlu değişkenler: boşsa BAŞLAMADAN dur ---------------------------
  local missing=()
  local required=(
    K8S_API_SERVER_HOST K8S_API_SERVER_PORT CLUSTER_POD_CIDR
    METALLB_IP_RANGE METALLB_POOL_NAME
    CEPH_OSD_DEVICE_FILTER CEPH_POOL_REPLICA_SIZE CEPH_POOL_MIN_REPLICA_SIZE
    CEPH_OBJECTSTORE_NAME
    HARBOR_ADMIN_PASSWORD HARBOR_HOSTNAME HARBOR_REGISTRY_BUCKET
    KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD
    KEYCLOAK_HOSTNAME KEYCLOAK_REALM
  )
  for v in "${required[@]}"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    err "${ENV_FILE} içinde şu zorunlu değişkenler boş:"
    printf '         - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  ok "Zorunlu değişkenlerin hepsi dolu"

  # --- Parola kalitesi: zayıf parola sessizce kabul edilmez ----------------
  local weak=() pw
  for v in HARBOR_ADMIN_PASSWORD KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD; do
    pw="${!v}"
    if (( ${#pw} < 14 )); then weak+=("$v (< 14 karakter)"); fi
  done
  case "${HARBOR_ADMIN_PASSWORD}" in
    Harbor12345|admin|password|changeme) weak+=("HARBOR_ADMIN_PASSWORD (bilinen varsayılan)") ;;
  esac
  if (( ${#weak[@]} > 0 )); then
    err "Zayıf parola tespit edildi:"
    printf '         - %s\n' "${weak[@]}" >&2
    err "Üretmek için:  openssl rand -base64 24"
    exit 1
  fi
  ok "Parola kalite kontrolü geçti"

  # --- kube-proxy kontrolü: Cilium replacement modu ile çakışır ------------
  if kubectl -n kube-system get daemonset kube-proxy >/dev/null 2>&1; then
    warn "kube-proxy DaemonSet'i BULUNDU."
    warn "Cilium kubeProxyReplacement=true ile çakışır (çift servis yönetimi)."
    warn "Kaldırmak için:"
    warn "    kubectl -n kube-system delete daemonset kube-proxy"
    warn "    kubectl -n kube-system delete configmap kube-proxy"
    warn "    # her node'da:  iptables-save | grep -v KUBE- | iptables-restore"
    confirm "kube-proxy duruyor. Yine de devam edilsin mi?" || exit 1
  else
    ok "kube-proxy yok — kube-proxy-free kurulum için doğru"
  fi

  # --- Node sayısı ---------------------------------------------------------
  local node_count
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log "Cluster'da ${node_count} node var"
  if (( node_count < 3 )); then
    warn "3'ten az node: Ceph replica=${CEPH_POOL_REPLICA_SIZE} karşılanamaz,"
    warn "havuzlar HEALTH_WARN'da kalır. Test için .env'de replica=1 yapın."
  fi
}

confirm() {
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  local reply
  read -r -p "$(printf '%s[?]%s %s [e/H] ' "${C_YLW}" "${C_RST}" "$1")" reply
  [[ "${reply}" =~ ^([eE]|[yY])$ ]]
}

# =============================================================================
# Yardımcılar
# =============================================================================

# Render edilirken DOLDURULACAK değişkenlerin açık listesi.
#
# NEDEN AÇIK LİSTE: çıplak `envsubst` ortamdaki HER değişkeni doldurur.
# ArgoCD multi-source manifestleri `$values/...` sözdizimini kullanır ve
# çıplak envsubst bunu sessizce BOŞALTIR — YAML geçerli kalır, hata ancak
# Faz 2'de sync sırasında anlaşılmaz bir mesaj olarak çıkar.
# Aynı şey `$HOME`, `$PATH` gibi her kaçak `$` için geçerlidir.
SUBST_VARS='${K8S_API_SERVER_HOST} ${K8S_API_SERVER_PORT} ${CLUSTER_POD_CIDR}
${METALLB_POOL_NAME} ${METALLB_AUTO_ASSIGN} ${METALLB_ADDRESSES_YAML_LIST}
${CEPH_OSD_DEVICE_FILTER} ${CEPH_POOL_REPLICA_SIZE} ${CEPH_POOL_MIN_REPLICA_SIZE}
${CEPH_OBJECTSTORE_NAME}
${HARBOR_HOSTNAME} ${HARBOR_REGISTRY_BUCKET} ${HARBOR_S3_ENDPOINT}
${HARBOR_CHART_VERSION} ${HARBOR_HELM_REPO}
${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_HOSTNAME} ${KEYCLOAK_REALM}
${KEYCLOAK_IMAGE_REGISTRY} ${KEYCLOAK_CHART_VERSION} ${KEYCLOAK_HELM_REPO}
${CILIUM_CHART_VERSION} ${CILIUM_HELM_REPO}
${METALLB_CHART_VERSION} ${METALLB_HELM_REPO}
${ROOK_CHART_VERSION} ${ROOK_HELM_REPO}
${DEFAULT_DENY_EXEMPT_YAML_LIST}
${PLATFORM_REPO_URL} ${PLATFORM_REPO_REVISION}
${PLATFORM_BASE_DOMAIN}'

# Şablonu render et. YALNIZCA SUBST_VARS'taki yer tutucular doldurulur;
# diğer $... dizileri (ArgoCD'nin $values'ı gibi) olduğu gibi kalır.
render() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "${dst}")"
  envsubst "${SUBST_VARS}" < "${src}" > "${dst}"

  # Doldurulmamış yer tutucu kaldıysa sessizce geçme — bu her zaman bir hatadır.
  # Yorum satırları hariç: şablon başlıklarındaki açıklamalar ${ORNEK} içerir.
  local leftover
  leftover="$(sed 's/#.*//' "${dst}" \
              | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | sort -u || true)"
  if [[ -n "${leftover}" ]]; then
    err "Render edilmemiş yer tutucular: ${dst}"
    printf '         %s\n' ${leftover} >&2
    err "SUBST_VARS listesine ekleyin veya .env'de tanımlayın."
    return 1
  fi
}

# Helm repo ekle — zaten varsa hata vermez (idempotent)
helm_repo() {
  local name="$1" url="$2"
  if helm repo list -o json 2>/dev/null | jq -e --arg n "$name" '.[]|select(.name==$n)' >/dev/null; then
    :
  else
    helm repo add "$name" "$url" >/dev/null
  fi
}

# Namespace'i idempotent yarat + platform etiketlerini bas
ensure_ns() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$ns" \
    platform.internal/layer=underlay \
    platform.internal/managed-by=underlay-bootstrap \
    --overwrite >/dev/null
}

# Secret'ı idempotent yarat/güncelle (apply ile, create ile değil)
ensure_secret() {
  local ns="$1" name="$2"; shift 2
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$ns" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Secret hazır: ${ns}/${name}"
}

# Koşul sağlanana kadar bekle. Zaman aşımında SON DURUMU yazdır —
# "timeout" deyip susmak, hata ayıklamayı imkânsız kılar.
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
  err "Son durum:"
  "$@" 2>&1 | sed 's/^/         /' >&2 || true
  return 1
}

helm_install() {
  local release="$1" chart="$2" ns="$3" version="$4"; shift 4
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install ${release} ${chart} --version ${version}"
    helm upgrade --install "${release}" "${chart}" \
      --namespace "${ns}" --version "${version}" --dry-run "$@" >/dev/null
    return 0
  fi
  # --install → idempotent. İkinci çalıştırmada upgrade olur, hata vermez.
  helm upgrade --install "${release}" "${chart}" \
    --namespace "${ns}" --create-namespace \
    --version "${version}" \
    --wait --timeout 15m \
    "$@"
}

# =============================================================================
# 1. Gateway API CRD'leri  (Cilium'dan ÖNCE — sıra zorunlu)
# =============================================================================
install_gateway_api() {
  step "1/7  Gateway API CRD'leri (${GATEWAY_API_VERSION}, ${GATEWAY_API_CHANNEL})"

  # Cilium gatewayAPI.enabled=true, CRD'ler yoksa agent hata verir.
  local base="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}"
  local url="${base}/${GATEWAY_API_CHANNEL}-install.yaml"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] kubectl apply -f ${url}"
    return 0
  fi

  # apply → idempotent
  kubectl apply -f "${url}"

  wait_for "Gateway API CRD'leri" 120 5 \
    kubectl get crd gatewayclasses.gateway.networking.k8s.io \
                    gateways.gateway.networking.k8s.io \
                    httproutes.gateway.networking.k8s.io

  verify_gateway_api
}

verify_gateway_api() {
  log "DOĞRULAMA: Gateway API"
  kubectl get crd -l gateway.networking.k8s.io/bundle-version 2>/dev/null \
    | sed 's/^/         /' || kubectl get crd | grep gateway.networking | sed 's/^/         /'
  ok "Gateway API CRD'leri kurulu"
}

# =============================================================================
# 2. Cilium
# =============================================================================
install_cilium() {
  step "2/7  Cilium ${CILIUM_CHART_VERSION} (kube-proxy replacement)"

  helm_repo cilium "${CILIUM_HELM_REPO}"
  helm repo update cilium >/dev/null

  render "${UNDERLAY_DIR}/cilium/values.yaml.tpl" \
         "${UNDERLAY_DIR}/cilium/values.rendered.yaml"
  ok "values render edildi (API server: ${K8S_API_SERVER_HOST}:${K8S_API_SERVER_PORT})"

  helm_install cilium cilium/cilium kube-system "${CILIUM_CHART_VERSION}" \
    -f "${UNDERLAY_DIR}/cilium/values.rendered.yaml"

  [[ "${DRY_RUN}" == "true" ]] && return 0

  wait_for "Cilium agent (DaemonSet)" 600 10 \
    kubectl -n kube-system rollout status daemonset/cilium --timeout=5s
  wait_for "Cilium operator" 300 10 \
    kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5s
  wait_for "Hubble Relay" 300 10 \
    kubectl -n kube-system rollout status deployment/hubble-relay --timeout=5s
  wait_for "Hubble UI" 300 10 \
    kubectl -n kube-system rollout status deployment/hubble-ui --timeout=5s

  verify_cilium
}

verify_cilium() {
  log "DOĞRULAMA: Cilium"

  # 1. cilium CLI varsa asıl doğrulama bu
  if command -v cilium >/dev/null 2>&1; then
    log "  \$ cilium status --wait"
    cilium status --wait --wait-duration 5m | sed 's/^/         /'
  else
    warn "  'cilium' CLI yok — agent içinden kontrol ediliyor"
    log "  \$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief"
    kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief 2>/dev/null \
      | sed 's/^/         /' \
      || kubectl -n kube-system exec ds/cilium -- cilium status --brief | sed 's/^/         /'
  fi

  # 2. kube-proxy replacement gerçekten aktif mi
  log "  \$ kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement"
  local kpr
  kpr="$(kubectl -n kube-system exec ds/cilium -- sh -c \
        'cilium-dbg status 2>/dev/null || cilium status' 2>/dev/null \
        | grep -i 'KubeProxyReplacement' || true)"
  printf '         %s\n' "${kpr:-(okunamadı)}"
  if [[ -n "${kpr}" && ! "${kpr}" =~ [Tt]rue|[Ss]trict ]]; then
    warn "  kube-proxy replacement BEKLENEN modda değil — values'ı kontrol edin"
  fi

  # 3. Gateway API controller kaydoldu mu
  log "  \$ kubectl get gatewayclass"
  kubectl get gatewayclass 2>/dev/null | sed 's/^/         /' \
    || warn "  GatewayClass yok — Cilium gateway controller kaydolmamış olabilir"

  # 4. Hubble akış görüyor mu
  log "  \$ kubectl -n kube-system get pods -l k8s-app=hubble-relay,k8s-app=hubble-ui"
  kubectl -n kube-system get pods \
    -l 'k8s-app in (hubble-relay,hubble-ui)' --no-headers 2>/dev/null \
    | sed 's/^/         /' || true

  ok "Cilium doğrulandı"
  log "  Hubble UI:  kubectl -n kube-system port-forward svc/hubble-ui 12000:80"
}

# =============================================================================
# 3. MetalLB
# =============================================================================
install_metallb() {
  step "3/7  MetalLB ${METALLB_CHART_VERSION} (L2 mode)"

  helm_repo metallb "${METALLB_HELM_REPO}"
  helm repo update metallb >/dev/null

  ensure_ns metallb-system
  # MetalLB speaker, node ağına ham erişim ister; PSA baseline bunu reddeder.
  kubectl label namespace metallb-system \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged --overwrite >/dev/null

  helm_install metallb metallb/metallb metallb-system "${METALLB_CHART_VERSION}" \
    -f "${UNDERLAY_DIR}/metallb/values.yaml"

  [[ "${DRY_RUN}" == "true" ]] && return 0

  wait_for "MetalLB controller" 300 10 \
    kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=5s
  wait_for "MetalLB speaker" 300 10 \
    kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=5s

  # CRD webhook'u hazır olmadan IPAddressPool apply edilirse reddedilir
  wait_for "MetalLB webhook" 180 5 \
    kubectl get validatingwebhookconfiguration metallb-webhook-configuration

  # --- Adres havuzunu render et --------------------------------------------
  # .env'deki virgüllü listeyi YAML listesine çevir (IP repoda durmaz)
  METALLB_ADDRESSES_YAML_LIST="$(
    echo "${METALLB_IP_RANGE}" | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
      | sed 's/^/    - "/;s/$/"/'
  )"
  export METALLB_ADDRESSES_YAML_LIST
  [[ -n "${METALLB_ADDRESSES_YAML_LIST}" ]] \
    || die "METALLB_IP_RANGE ayrıştırılamadı: '${METALLB_IP_RANGE}'"

  render "${UNDERLAY_DIR}/metallb/ipaddresspool.yaml.tpl" \
         "${UNDERLAY_DIR}/metallb/rendered/ipaddresspool.yaml"

  # Webhook geçici olarak hazır olmayabilir → kısa retry
  local tries=0
  until kubectl apply -f "${UNDERLAY_DIR}/metallb/rendered/ipaddresspool.yaml"; do
    tries=$(( tries + 1 )); (( tries > 6 )) && die "IPAddressPool apply edilemedi"
    warn "  webhook henüz hazır değil, 10s sonra tekrar (${tries}/6)"; sleep 10
  done

  verify_metallb
}

verify_metallb() {
  log "DOĞRULAMA: MetalLB"

  log "  \$ kubectl -n metallb-system get ipaddresspool,l2advertisement"
  kubectl -n metallb-system get ipaddresspool,l2advertisement | sed 's/^/         /'

  # Asıl doğrulama: geçici bir LoadBalancer Service gerçekten IP alıyor mu?
  log "  Smoke test: geçici LoadBalancer Service IP alıyor mu?"
  local ns="metallb-smoketest"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${ns}" create service loadbalancer lb-probe --tcp=80:80 \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local ip="" i=0
  while (( i < 30 )); do
    ip="$(kubectl -n "${ns}" get svc lb-probe \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${ip}" ]] && break
    sleep 4; i=$(( i + 1 ))
  done

  kubectl delete namespace "${ns}" --wait=false >/dev/null 2>&1 || true

  if [[ -n "${ip}" ]]; then
    ok "MetalLB doğrulandı — havuzdan atanan IP: ${ip}"
    log "  (Faz 1 Definition of Done: 'LoadBalancer tipi Service harici IP alıyor' ✅)"
  else
    err "LoadBalancer Service IP ALAMADI."
    err "Kontrol edin:"
    err "  - METALLB_IP_RANGE node'ların L2 segmentinde mi?"
    err "  - kubectl -n metallb-system logs deploy/metallb-controller"
    return 1
  fi
}

# =============================================================================
# 4. Rook-Ceph
# =============================================================================
install_rook() {
  step "4/7  Rook-Ceph ${ROOK_CHART_VERSION} (blok + paylaşımlı + obje)"

  helm_repo rook-release "${ROOK_HELM_REPO}"
  helm repo update rook-release >/dev/null

  ensure_ns rook-ceph
  kubectl label namespace rook-ceph \
    pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

  # --- Operator ------------------------------------------------------------
  helm_install rook-ceph rook-release/rook-ceph rook-ceph "${ROOK_CHART_VERSION}" \
    -f "${UNDERLAY_DIR}/rook-ceph/operator-values.yaml"

  [[ "${DRY_RUN}" == "true" ]] && { render_rook; return 0; }

  wait_for "Rook operator" 300 10 \
    kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=5s

  wait_for "Rook CRD'leri" 180 5 \
    kubectl get crd cephclusters.ceph.rook.io cephblockpools.ceph.rook.io \
                    cephfilesystems.ceph.rook.io cephobjectstores.ceph.rook.io

  # --- YIKICI ADIM: disk onayı --------------------------------------------
  warn "─────────────────────────────────────────────────────────────────"
  warn " CephCluster uygulanmak üzere."
  warn " deviceFilter: '${CEPH_OSD_DEVICE_FILTER}'"
  warn " Bu filtreyle EŞLEŞEN DİSKLERİN ÜZERİNDEKİ TÜM VERİ SİLİNİR."
  warn ""
  warn " Hangi diskler etkilenecek — her node'da kontrol edin:"
  warn "   lsblk -dno NAME,SIZE,TYPE,MOUNTPOINT"
  warn "─────────────────────────────────────────────────────────────────"
  if ! kubectl -n rook-ceph get cephcluster platform-ceph >/dev/null 2>&1; then
    confirm "Diskler silinsin ve CephCluster oluşturulsun mu?" \
      || die "Kullanıcı iptal etti. CephCluster oluşturulmadı."
  else
    log "CephCluster zaten var — mevcut cluster güncelleniyor (disk silinmez)"
  fi

  render_rook
  kubectl apply -f "${UNDERLAY_DIR}/rook-ceph/rendered/cephcluster.yaml"

  # OSD hazırlığı yavaştır: disk zeroing + BlueStore init. 20 dk makul.
  wait_for "CephCluster HEALTH_OK/HEALTH_WARN" 1800 20 \
    bash -c 'kubectl -n rook-ceph get cephcluster platform-ceph \
      -o jsonpath="{.status.ceph.health}" 2>/dev/null | grep -Eq "HEALTH_OK|HEALTH_WARN"'

  wait_for "CephCluster Ready" 600 15 \
    bash -c 'kubectl -n rook-ceph get cephcluster platform-ceph \
      -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "Ready"'

  # --- Havuzlar, filesystem, object store ---------------------------------
  kubectl apply -f "${UNDERLAY_DIR}/rook-ceph/rendered/cephblockpool.yaml"
  kubectl apply -f "${UNDERLAY_DIR}/rook-ceph/rendered/cephfilesystem.yaml"
  kubectl apply -f "${UNDERLAY_DIR}/rook-ceph/rendered/cephobjectstore.yaml"

  wait_for "CephBlockPool Ready" 600 10 \
    bash -c 'kubectl -n rook-ceph get cephblockpool platform-blockpool \
      -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "Ready"'

  wait_for "CephFilesystem Ready" 600 10 \
    bash -c 'kubectl -n rook-ceph get cephfilesystem platform-fs \
      -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "Ready"'

  wait_for "CephObjectStore (RGW) Ready" 900 15 \
    bash -c "kubectl -n rook-ceph get cephobjectstore ${CEPH_OBJECTSTORE_NAME} \
      -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Ready'"

  wait_for "RGW deployment" 600 10 \
    bash -c "kubectl -n rook-ceph get deploy \
      -l rgw=${CEPH_OBJECTSTORE_NAME} -o name | grep -q ."

  # --- StorageClass'lar ----------------------------------------------------
  kubectl apply -f "${UNDERLAY_DIR}/storage-classes/rendered/storageclasses.yaml"

  # --- Bucket'lar ----------------------------------------------------------
  kubectl apply -f "${UNDERLAY_DIR}/rook-ceph/rendered/objectbucketclaims.yaml"

  wait_for "backup-bucket (OBC) Bound" 300 10 \
    bash -c 'kubectl -n rook-ceph get obc backup-bucket \
      -o jsonpath="{.status.phase}" 2>/dev/null | grep -q "Bound"'

  wait_for "${HARBOR_REGISTRY_BUCKET} (OBC) Bound" 300 10 \
    bash -c "kubectl -n rook-ceph get obc ${HARBOR_REGISTRY_BUCKET} \
      -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Bound'"

  verify_rook
}

render_rook() {
  for f in cephcluster cephblockpool cephfilesystem cephobjectstore objectbucketclaims; do
    render "${UNDERLAY_DIR}/rook-ceph/${f}.yaml.tpl" \
           "${UNDERLAY_DIR}/rook-ceph/rendered/${f}.yaml"
  done
  render "${UNDERLAY_DIR}/storage-classes/storageclasses.yaml.tpl" \
         "${UNDERLAY_DIR}/storage-classes/rendered/storageclasses.yaml"
  ok "Rook manifestleri render edildi"
}

verify_rook() {
  log "DOĞRULAMA: Rook-Ceph"

  log "  \$ kubectl get storageclass"
  kubectl get storageclass | sed 's/^/         /'

  log "  \$ kubectl -n rook-ceph get cephcluster"
  kubectl -n rook-ceph get cephcluster | sed 's/^/         /'

  log "  \$ ceph status  (toolbox üzerinden)"
  if kubectl -n rook-ceph get deploy rook-ceph-tools >/dev/null 2>&1; then
    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status \
      2>/dev/null | sed 's/^/         /' || warn "  toolbox'a ulaşılamadı"
  else
    log "  (toolbox kurulu değil; kurmak için:"
    log "     helm upgrade rook-ceph rook-release/rook-ceph -n rook-ceph \\"
    log "       --reuse-values --set toolbox.enabled=true )"
  fi

  log "  \$ kubectl -n rook-ceph get obc"
  kubectl -n rook-ceph get obc | sed 's/^/         /'

  # Asıl doğrulama: PVC gerçekten bağlanıyor mu (RWO ve RWX)
  log "  Smoke test: RWO + RWX PVC bağlanıyor mu?"
  local ns="ceph-smoketest"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "${ns}" apply -f - >/dev/null <<PVCEOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: probe-rwo}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: probe-rwx}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: ceph-filesystem
  resources: {requests: {storage: 1Gi}}
PVCEOF

  local rwo="" rwx="" i=0
  while (( i < 30 )); do
    rwo="$(kubectl -n "${ns}" get pvc probe-rwo -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    rwx="$(kubectl -n "${ns}" get pvc probe-rwx -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${rwo}" == "Bound" && "${rwx}" == "Bound" ]] && break
    sleep 5; i=$(( i + 1 ))
  done
  printf '         RWO (ceph-block):      %s\n' "${rwo:-?}"
  printf '         RWX (ceph-filesystem): %s\n' "${rwx:-?}"
  kubectl delete namespace "${ns}" --wait=false >/dev/null 2>&1 || true

  if [[ "${rwo}" == "Bound" && "${rwx}" == "Bound" ]]; then
    ok "Rook-Ceph doğrulandı — RWO ve RWX PVC bağlanıyor"
    log "  (Faz 1 Definition of Done: 'RWO+RWX PVC bağlanıyor' ✅)"
  else
    err "PVC bağlanmadı. Kontrol: kubectl -n rook-ceph logs deploy/rook-ceph-operator"
    return 1
  fi
}

# =============================================================================
# 5. Keycloak   (control-plane; Harbor'dan ÖNCE — OIDC sağlayıcı)
# =============================================================================
install_keycloak() {
  step "5/7  Keycloak ${KEYCLOAK_CHART_VERSION} (OIDC sağlayıcı)"

  helm_repo bitnami "${KEYCLOAK_HELM_REPO}"
  helm repo update bitnami >/dev/null

  ensure_ns keycloak
  kubectl label namespace keycloak platform.internal/layer=control-plane --overwrite >/dev/null

  # --- Sırlar: .env'den, Git'ten DEĞİL -------------------------------------
  ensure_secret keycloak keycloak-admin-password \
    "admin-password=${KEYCLOAK_ADMIN_PASSWORD}"
  ensure_secret keycloak keycloak-db-password \
    "password=${KEYCLOAK_DB_PASSWORD}" \
    "postgres-password=${KEYCLOAK_DB_PASSWORD}"

  # --- Realm import ConfigMap ---------------------------------------------
  # DÜZELTME (Faz 12b, GERÇEK bir kind cluster'ında keşfedildi): realm-
  # platform.json.tpl daha önce dokümantasyon amaçlı "_comment" alanları
  # içeriyordu (hem realm kök seviyesinde hem client'larda) — ama Keycloak
  # 26.x'in JSON deserializer'ı (Jackson, FAIL_ON_UNKNOWN_PROPERTIES) BU
  # BİLİNMEYEN ALANLARLA KARŞILAŞINCA import'u REDDEDİYOR, ve dev-mode'da
  # import BAŞLANGIÇTA (boot sırasında) çalıştığından bu, Keycloak pod'unun
  # HER ZAMAN CrashLoopBackOff'a girmesine yol açıyordu — canlı olarak
  # doğrulandı (`_comment` gerçek JSON alanı olarak asla desteklenmedi, bu
  # dosya daha önce hiç gerçek bir Keycloak'a import EDİLMEMİŞTİ). "_comment"
  # alanları KALDIRILDI; açıklamaları artık burada (render çağrısının
  # üzerinde) ve dosyanın git geçmişinde.
  #
  # ESKİ İÇERİK (JSON'dan çıkarıldı):
  #   - Realm kökü: "Platform realm — Faz 1 taban tanımı. Client'lar BURAYA
  #     EKLENMEZ; her bileşen kendi fazında kendi client'ını ekler (ArgoCD:
  #     Faz 2, Vault: Faz 3, Harbor/Grafana: Faz 4, Backstage: Faz 8).
  #     Gerekçe: client secret'ları Git'te duramaz; client'lar Faz 3'ten
  #     sonra Vault + ESO üzerinden yönetilecek (ADR-0001 Karar 2.3).
  #     conventions.md §5: Keycloak grubu = tenant-<name>, client =
  #     <name>-<env>."
  #   - "kubernetes" client: PUBLIC client (secret YOK) — kubectl/oidc-login
  #     gibi istemciler PKCE ile interaktif login yapar, bir API server/
  #     servis DEĞİLDİR, bu yüzden confidential client GEREKMEZ. Gerçek
  #     kullanım: docs/runbooks/k8s-api-server-oidc.md.
  #   - "backstage" client: Secret BURADA YOK — Keycloak import sırasında
  #     otomatik üretir; 04-backstage.sh bu secret'ı Keycloak Admin API'den
  #     okuyup Vault'a yazar (KV), ESO oradan Backstage'in kendi Secret'ına
  #     çeker (ADR-0001 Karar 2.3).
  render "${CONTROL_PLANE_DIR}/keycloak/realm-platform.json.tpl" \
         "${CONTROL_PLANE_DIR}/keycloak/rendered/realm-platform.json"
  kubectl -n keycloak create configmap keycloak-realm-import \
    --from-file="${KEYCLOAK_REALM}-realm.json=${CONTROL_PLANE_DIR}/keycloak/rendered/realm-platform.json" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Realm import ConfigMap hazır (realm: ${KEYCLOAK_REALM})"

  render "${CONTROL_PLANE_DIR}/keycloak/values.yaml.tpl" \
         "${CONTROL_PLANE_DIR}/keycloak/values.rendered.yaml"

  helm_install keycloak bitnami/keycloak keycloak "${KEYCLOAK_CHART_VERSION}" \
    -f "${CONTROL_PLANE_DIR}/keycloak/values.rendered.yaml"

  [[ "${DRY_RUN}" == "true" ]] && return 0

  wait_for "Keycloak StatefulSet" 900 15 \
    kubectl -n keycloak rollout status statefulset/keycloak --timeout=5s

  verify_keycloak
}

verify_keycloak() {
  log "DOĞRULAMA: Keycloak"

  log "  \$ kubectl -n keycloak get pods,svc"
  kubectl -n keycloak get pods,svc | sed 's/^/         /'

  local lb
  lb="$(kubectl -n keycloak get svc keycloak \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${lb}" ]] && ok "  MetalLB IP: ${lb}"

  # OIDC discovery — asıl doğrulama bu. Realm import edilmediyse 404 döner.
  local disco="/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
  log "  \$ curl -sf http://<keycloak>${disco}"
  local body
  body="$(kubectl -n keycloak run kc-verify-$$ --rm -i --restart=Never \
          --image=curlimages/curl:8.10.1 --quiet -- \
          curl -sf --max-time 20 "http://keycloak.keycloak.svc${disco}" 2>/dev/null || true)"

  if [[ -n "${body}" ]] && echo "${body}" | jq -e '.issuer' >/dev/null 2>&1; then
    ok "  OIDC discovery yanıt verdi"
    printf '         issuer:                 %s\n' "$(echo "${body}" | jq -r '.issuer')"
    printf '         authorization_endpoint: %s\n' "$(echo "${body}" | jq -r '.authorization_endpoint')"
    printf '         jwks_uri:               %s\n' "$(echo "${body}" | jq -r '.jwks_uri')"
    ok "Keycloak doğrulandı — realm '${KEYCLOAK_REALM}' yayında"
  else
    err "  OIDC discovery BAŞARISIZ (realm '${KEYCLOAK_REALM}')."
    err "  Realm import edilmemiş olabilir:"
    err "    kubectl -n keycloak logs sts/keycloak | grep -i import"
    return 1
  fi

  warn "  NOT: issuer URL'i '${KEYCLOAK_HOSTNAME}' olmalı. Değilse, bu realm'e"
  warn "  bağlanan her istemci (ArgoCD/Harbor/Vault) token'ı sessizce reddeder."
}

# =============================================================================
# 6. Harbor   (control-plane; Rook RGW'yi backend olarak kullanır)
# =============================================================================
install_harbor() {
  step "6/7  Harbor ${HARBOR_CHART_VERSION} (registry + Trivy, S3 backend: Ceph RGW)"

  helm_repo harbor "${HARBOR_HELM_REPO}"
  helm repo update harbor >/dev/null

  ensure_ns harbor
  kubectl label namespace harbor platform.internal/layer=control-plane --overwrite >/dev/null

  # --- S3 kimlik bilgilerini Rook'un OBC secret'ından al -------------------
  # Bu değerler Rook tarafından üretilir ve Git'e HİÇ girmez.
  log "Rook OBC'den S3 kimlik bilgileri okunuyor (${HARBOR_REGISTRY_BUCKET})"
  local s3_key s3_secret s3_host s3_port
  s3_key="$(kubectl -n rook-ceph get secret "${HARBOR_REGISTRY_BUCKET}" \
            -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)"
  s3_secret="$(kubectl -n rook-ceph get secret "${HARBOR_REGISTRY_BUCKET}" \
            -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)"
  s3_host="$(kubectl -n rook-ceph get configmap "${HARBOR_REGISTRY_BUCKET}" \
            -o jsonpath='{.data.BUCKET_HOST}' 2>/dev/null || true)"
  s3_port="$(kubectl -n rook-ceph get configmap "${HARBOR_REGISTRY_BUCKET}" \
            -o jsonpath='{.data.BUCKET_PORT}' 2>/dev/null || true)"

  [[ -n "${s3_key}" && -n "${s3_secret}" ]] \
    || die "OBC '${HARBOR_REGISTRY_BUCKET}' secret'ı okunamadı. Rook adımı tamam mı?
     kubectl -n rook-ceph get obc ${HARBOR_REGISTRY_BUCKET}"
  [[ -n "${s3_host}" ]] \
    || die "OBC ConfigMap'inden BUCKET_HOST okunamadı."

  export HARBOR_S3_ENDPOINT="http://${s3_host}:${s3_port:-80}"
  ok "RGW endpoint: ${HARBOR_S3_ENDPOINT}"

  # !!! DOĞRULAMA GEREKLİ: anahtar isimleri chart sürümüne bağlı.
  #     helm show values harbor/harbor --version ${HARBOR_CHART_VERSION} \
  #       | grep -A25 imageChartStorage
  ensure_secret harbor harbor-registry-s3 \
    "REGISTRY_STORAGE_S3_ACCESSKEY=${s3_key}" \
    "REGISTRY_STORAGE_S3_SECRETKEY=${s3_secret}"

  ensure_secret harbor harbor-admin-password \
    "HARBOR_ADMIN_PASSWORD=${HARBOR_ADMIN_PASSWORD}"

  # Harbor'un iç PostgreSQL'i için parola (Faz 4'te CNPG'ye taşınacak)
  ensure_secret harbor harbor-database-password \
    "password=${HARBOR_ADMIN_PASSWORD}"

  render "${CONTROL_PLANE_DIR}/harbor/values.yaml.tpl" \
         "${CONTROL_PLANE_DIR}/harbor/values.rendered.yaml"

  helm_install harbor harbor/harbor harbor "${HARBOR_CHART_VERSION}" \
    -f "${CONTROL_PLANE_DIR}/harbor/values.rendered.yaml"

  [[ "${DRY_RUN}" == "true" ]] && return 0

  for d in harbor-core harbor-portal harbor-registry harbor-jobservice harbor-trivy; do
    if kubectl -n harbor get deploy "$d" >/dev/null 2>&1; then
      wait_for "Harbor ${d}" 900 15 \
        kubectl -n harbor rollout status "deployment/${d}" --timeout=5s
    elif kubectl -n harbor get statefulset "$d" >/dev/null 2>&1; then
      wait_for "Harbor ${d}" 900 15 \
        kubectl -n harbor rollout status "statefulset/${d}" --timeout=5s
    fi
  done

  configure_harbor_security_policy
  verify_harbor
}

# =============================================================================
# Faz 10, görev madde 4: "library" projesinde (varsayılan proje — Faz 6'nın
# tenant-özel Harbor projeleri henüz YOK, bkz. PLATFORM_CONTEXT.md teknik
# borç) Trivy taramasını ZORUNLU kıl + kritik/yüksek zafiyetli imajların
# ÇALIŞTIRILMASINI Harbor seviyesinde ENGELLE.
#
# NEDEN CI GATE'İ (image-supply-chain.yaml) YETMİYOR: CI, yalnızca O
# PIPELINE'DAN geçen push'ları durdurur — `docker push` ile CI'yı BYPASS
# EDEN biri (veya eski bir imajı retag'leyen biri) Harbor'un KENDİ
# `prevent_vul` ayarı olmadan hâlâ zafiyetli bir imajı push/çalıştırabilirdi.
# Bu, CI gate'ine EK, registry-seviyeli ikinci bir savunma katmanıdır (Faz
# 10'un "iki katmanlı savunma" ilkesiyle — bkz. PSS cluster-wide — TUTARLI).
# =============================================================================
configure_harbor_security_policy() {
  log "Harbor proje güvenlik politikası: auto-scan + prevent-vulnerable (severity=high)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] library projesine auto_scan/prevent_vul PUT edilecekti"
    return 0
  fi

  local payload='{"metadata":{"auto_scan":"true","prevent_vul":"true","severity":"high","reuse_sys_cve_allowlist":"true"}}'
  kubectl -n harbor run harbor-secpolicy-$$ --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    curl -sf --max-time 20 -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    -X PUT -H "Content-Type: application/json" \
    -d "${payload}" \
    "http://harbor.harbor.svc/api/v2.0/projects/library" \
    && ok "  library projesi: auto_scan=true, prevent_vul=true, severity=high" \
    || warn "  Proje güvenlik politikası uygulanamadı — Harbor henüz tam ayakta olmayabilir (--only harbor ile tekrar deneyin)"
}

verify_harbor() {
  log "DOĞRULAMA: Harbor"

  log "  \$ kubectl -n harbor get pods,svc"
  kubectl -n harbor get pods,svc | sed 's/^/         /'

  local lb
  lb="$(kubectl -n harbor get svc harbor \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [[ -n "${lb}" ]] && ok "  MetalLB IP: ${lb}"

  # 1. Health endpoint
  log "  \$ curl -sf http://<harbor>/api/v2.0/health"
  local health
  health="$(kubectl -n harbor run harbor-verify-$$ --rm -i --restart=Never \
            --image=curlimages/curl:8.10.1 --quiet -- \
            curl -sf --max-time 20 "http://harbor.harbor.svc/api/v2.0/health" 2>/dev/null || true)"

  if [[ -n "${health}" ]] && echo "${health}" | jq -e '.status' >/dev/null 2>&1; then
    printf '         genel durum: %s\n' "$(echo "${health}" | jq -r '.status')"
    echo "${health}" | jq -r '.components[] | "         \(.name): \(.status)"' 2>/dev/null || true

    local unhealthy
    unhealthy="$(echo "${health}" | jq -r '[.components[]|select(.status!="healthy")]|length' 2>/dev/null || echo 0)"
    if [[ "${unhealthy}" != "0" ]]; then
      err "  ${unhealthy} bileşen sağlıksız (yukarıda)."
      return 1
    fi
    ok "  Tüm Harbor bileşenleri healthy"
  else
    err "  Health endpoint yanıt vermedi."
    err "    kubectl -n harbor logs deploy/harbor-core"
    return 1
  fi

  # 2. Trivy scanner kayıtlı mı — "Trivy taraması otomatik" için ön koşul
  log "  \$ curl .../api/v2.0/scanners   (Trivy kayıtlı mı)"
  local scanners
  scanners="$(kubectl -n harbor run harbor-scan-$$ --rm -i --restart=Never \
              --image=curlimages/curl:8.10.1 --quiet -- \
              curl -sf --max-time 20 -u "admin:${HARBOR_ADMIN_PASSWORD}" \
              "http://harbor.harbor.svc/api/v2.0/scanners" 2>/dev/null || true)"
  if [[ -n "${scanners}" ]] && echo "${scanners}" | jq -e '.[0].name' >/dev/null 2>&1; then
    echo "${scanners}" | jq -r '.[] | "         \(.name)  default=\(.is_default)  health=\(.health // "?")"'
    ok "  Trivy scanner kayıtlı"
  else
    warn "  Scanner listesi okunamadı — Trivy henüz kaydolmamış olabilir."
    warn "  Birkaç dakika sonra tekrar: --only harbor --verify-only"
  fi

  # 3. S3 backend gerçekten RGW'yi mi gösteriyor
  log "  \$ registry config: storage backend"
  kubectl -n harbor get cm harbor-registry -o jsonpath='{.data.config\.yml}' 2>/dev/null \
    | grep -A6 -E '^ *s3:' | sed 's/^/         /' \
    || warn "  registry ConfigMap okunamadı (chart sürümüne göre ad değişebilir)"

  ok "Harbor doğrulandı"
  log "  Proje oluşturma (Faz 6'da composition yapacak) — otomatik tarama için:"
  log "    curl -u admin:*** -X POST http://<harbor>/api/v2.0/projects \\"
  log "      -H 'Content-Type: application/json' \\"
  log "      -d '{\"project_name\":\"<tenant>\",\"metadata\":{\"auto_scan\":\"true\"}}'"
}

# =============================================================================
# 7. Ağ politikaları (default-deny)  — EN SON
# =============================================================================
install_network_policies() {
  step "7/7  Cilium ağ politikaları"

  # İzin politikaları her zaman, ENABLE_DEFAULT_DENY kontrolünden ÖNCE
  # uygulanır — bunlar KISITLAYICI DEĞİLDİR (code review #4'te bu iddia
  # CANLI/statik olarak sınandı: ccnp-00/01'in KENDİLERİ `enableDefaultDeny:
  # {ingress: false, egress: false}` TAŞIR — bu OLMADAN Cilium'un GERÇEK
  # semantiği, bir `egress`/`ingress` kural listesi tanımlayan HER
  # politikanın o yön için İMPLİCİT default-deny'i KENDİLİĞİNDEN
  # etkinleştirmesiydi, ENABLE_DEFAULT_DENY bayrağından TAMAMEN BAĞIMSIZ —
  # yani bu iki dosya `enableDefaultDeny:false` OLMADAN uygulandığında,
  # "default-deny KAPALI" sanılan bir kurulumda bile KÜMEDEKİ HER pod'un
  # egress'i SESSİZCE yalnızca DNS'e KISITLANIRDI. Bkz. ccnp-00-allow-dns.
  # yaml'ın başlık yorumu).
  kubectl apply -f "${UNDERLAY_DIR}/cilium/ccnp-00-allow-dns.yaml"
  kubectl apply -f "${UNDERLAY_DIR}/cilium/ccnp-01-allow-health.yaml"
  ok "İzin politikaları uygulandı (DNS, health)"

  if [[ "${ENABLE_DEFAULT_DENY,,}" != "true" ]]; then
    warn "default-deny ATLANDI (ENABLE_DEFAULT_DENY=${ENABLE_DEFAULT_DENY})."
    warn ""
    warn "Bu KASITLI bir varsayılandır: default-deny, henüz açık politikası"
    warn "olmayan bileşenlerin trafiğini keser ve arıza 'ağ sorunu' gibi değil"
    warn "'kurulum takıldı' gibi görünür."
    warn ""
    warn "Her şey sağlıklı olduğunu doğruladıktan SONRA:"
    warn "  1) .env'de ENABLE_DEFAULT_DENY=true"
    warn "  2) ./platform/bootstrap/01-underlay.sh --only policies"
    warn "  3) hubble observe --verdict DROPPED --follow   (izleyin)"
    return 0
  fi

  # --- Muaf namespace listesini YAML listesine çevir ------------------------
  DEFAULT_DENY_EXEMPT_YAML_LIST="$(
    echo "${DEFAULT_DENY_EXEMPT_NAMESPACES}" | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' \
      | sed 's/^/          - "/;s/$/"/'
  )"
  export DEFAULT_DENY_EXEMPT_YAML_LIST

  render "${UNDERLAY_DIR}/cilium/ccnp-99-default-deny.yaml.tpl" \
         "${UNDERLAY_DIR}/cilium/rendered/ccnp-99-default-deny.yaml"

  warn "─────────────────────────────────────────────────────────────────"
  warn " CLUSTER-WIDE DEFAULT-DENY uygulanmak üzere."
  warn " Muaf namespace'ler: ${DEFAULT_DENY_EXEMPT_NAMESPACES}"
  warn " Bunların DIŞINDAKİ tüm trafik kesilecek."
  warn " Geri alma: kubectl delete ccnp platform-default-deny"
  warn "─────────────────────────────────────────────────────────────────"
  confirm "default-deny uygulansın mı?" || { warn "Atlandı."; return 0; }

  # İzin politikalarını da rendered/ altına kopyala (ArgoCD Faz 2'de buradan çeker)
  mkdir -p "${UNDERLAY_DIR}/cilium/rendered"
  cp "${UNDERLAY_DIR}/cilium/ccnp-00-allow-dns.yaml" \
     "${UNDERLAY_DIR}/cilium/ccnp-01-allow-health.yaml" \
     "${UNDERLAY_DIR}/cilium/rendered/"

  kubectl apply -f "${UNDERLAY_DIR}/cilium/rendered/ccnp-99-default-deny.yaml"

  verify_policies
}

verify_policies() {
  log "DOĞRULAMA: Ağ politikaları"

  log "  \$ kubectl get ciliumclusterwidenetworkpolicy"
  kubectl get ciliumclusterwidenetworkpolicy | sed 's/^/         /'

  # default-deny sonrası DNS hâlâ çalışıyor mu? En kritik regresyon budur.
  log "  Smoke test: default-deny sonrası DNS çözümlemesi"
  local ns="policy-smoketest"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local dns_ok="false"
  if kubectl -n "${ns}" run dns-probe-$$ --rm -i --restart=Never \
      --image=busybox:1.36 --quiet --pod-running-timeout=90s -- \
      nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    dns_ok="true"
  fi
  kubectl delete namespace "${ns}" --wait=false >/dev/null 2>&1 || true

  if [[ "${dns_ok}" == "true" ]]; then
    ok "  DNS çözümlemesi çalışıyor (allow-dns politikası etkili)"
  else
    err "  DNS ÇÖZÜMLEMESİ BAŞARISIZ — default-deny DNS'i kesmiş olabilir."
    err "  Hemen geri alın:  kubectl delete ccnp platform-default-deny"
    err "  İnceleyin:        hubble observe --verdict DROPPED --last 50"
    return 1
  fi

  log "  Düşen akışları izlemek için:"
  log "    cilium hubble port-forward &"
  log "    hubble observe --verdict DROPPED --follow"
  ok "Ağ politikaları doğrulandı"
}

# =============================================================================
# Özet
# =============================================================================
summary() {
  step "Özet"
  printf '\n  %-14s %-10s %s\n' "BİLEŞEN" "NAMESPACE" "DURUM"
  printf '  %s\n' "────────────────────────────────────────────────────────"
  local rows=(
    "Cilium|kube-system|daemonset/cilium"
    "MetalLB|metallb-system|deployment/metallb-controller"
    "Rook-Ceph|rook-ceph|deployment/rook-ceph-operator"
    "Keycloak|keycloak|statefulset/keycloak"
    "Harbor|harbor|deployment/harbor-core"
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r name ns res <<< "${row}"
    local state="${C_RED}yok${C_RST}"
    if kubectl -n "${ns}" get "${res}" >/dev/null 2>&1; then
      if kubectl -n "${ns}" rollout status "${res}" --timeout=3s >/dev/null 2>&1; then
        state="${C_GRN}çalışıyor${C_RST}"
      else
        state="${C_YLW}hazır değil${C_RST}"
      fi
    fi
    printf '  %-14s %-14s %b\n' "${name}" "${ns}" "${state}"
  done

  cat <<EOS

  Sonraki adımlar
  ───────────────
  1. PLATFORM_CONTEXT.md "Kurulu bileşenler" tablosunu GERÇEK durumla güncelleyin
     (sürüm, tarih, doğrulama komutu). Repoda YAML olması yeterli değildir.
  2. default-deny hâlâ kapalıysa: her şeyi doğrulayın, sonra
     .env → ENABLE_DEFAULT_DENY=true → $0 --only policies
  3. Faz 2: ArgoCD + app-of-apps.
     Faz 1'de elle kurulan release'lerin ArgoCD'ye devri:
     platform/bootstrap/README.md "Faz 1 → Faz 2 devralma"

  Erişim
  ──────
  Hubble UI      kubectl -n kube-system port-forward svc/hubble-ui 12000:80
  Ceph dashboard kubectl -n rook-ceph port-forward svc/rook-ceph-mgr-dashboard 7000:7000
  Harbor         kubectl -n harbor get svc harbor
  Keycloak       kubectl -n keycloak get svc keycloak

EOS
}

# =============================================================================
# main
# =============================================================================
main() {
  log "Faz 1 — Underlay kurulumu"
  [[ "${DRY_RUN}"     == "true" ]] && warn "DRY-RUN: hiçbir değişiklik uygulanmaz"
  [[ "${VERIFY_ONLY}" == "true" ]] && warn "VERIFY-ONLY: yalnızca doğrulama"
  [[ -n "${ONLY}"               ]] && log  "Yalnızca adım: ${ONLY}"

  preflight

  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    should_run gateway  && verify_gateway_api || true
    should_run cilium   && verify_cilium      || true
    should_run metallb  && verify_metallb     || true
    should_run rook     && verify_rook        || true
    should_run keycloak && verify_keycloak    || true
    should_run harbor   && verify_harbor      || true
    should_run policies && verify_policies    || true
    summary
    return 0
  fi

  should_run gateway  && install_gateway_api
  should_run cilium   && install_cilium
  should_run metallb  && install_metallb
  should_run rook     && install_rook
  should_run keycloak && install_keycloak
  should_run harbor   && install_harbor
  should_run policies && install_network_policies

  summary
  ok "Faz 1 tamamlandı."
}

main "$@"
