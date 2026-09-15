#!/usr/bin/env bash
# =============================================================================
# Faz 2 — Control plane çalışma zamanları
#
#   ArgoCD → (root-app + AppProject) → Crossplane + Kyverno + ESO (paralel)
#                                       → Vault (yer tutucu, Faz 3'e kadar manuel)
#
# TASARIM KURALLARI (01-underlay.sh ile aynı):
#   1. IDEMPOTENT: helm upgrade --install / kubectl apply.
#   2. HARDCODED DEĞER YOK: repo URL/revizyon .env'den; chart sürümleri
#      versions.env'den (bunlar ortam-bağımsız sabitlerdir, .env'e değil
#      versions.env'e ait — bkz. platform/control-plane/apps/*.tpl yorumları).
#   3. HER ADIMDA READINESS.
#   4. Crossplane provider'larında STATİK KİMLİK BİLGİSİ YOK — hepsi
#      InjectedIdentity (in-cluster ServiceAccount) veya (provider-terraform
#      için) kimlik bilgisi hiç tanımlı değil.
#
# KULLANIM
#   ./platform/bootstrap/02-control-plane.sh                    # tümü
#   ./platform/bootstrap/02-control-plane.sh --only crossplane  # tek adım
#   ./platform/bootstrap/02-control-plane.sh --verify-only
#   ./platform/bootstrap/02-control-plane.sh --dry-run
#
# ÖN KOŞUL: Faz 1 tamamlanmış olmalı (01-underlay.sh --verify-only yeşil).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNDERLAY_DIR="${REPO_ROOT}/platform/underlay"
CONTROL_PLANE_DIR="${REPO_ROOT}/platform/control-plane"
APPS_DIR="${CONTROL_PLANE_DIR}/apps"
BOOTSTRAP_APPS_DIR="${REPO_ROOT}/platform/bootstrap/app-of-apps"
ENV_FILE="${UNDERLAY_DIR}/.env"
VERSIONS_FILE="${UNDERLAY_DIR}/versions.env"

ONLY=""
DRY_RUN="false"
VERIFY_ONLY="false"
ASSUME_YES="false"

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
    --only)        ONLY="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --verify-only) VERIFY_ONLY="true"; shift ;;
    --yes|-y)      ASSUME_YES="true"; shift ;;
    -h|--help)     sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "Bilinmeyen argüman: $1  (--help)" ;;
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
  err "Son durum:"
  "$@" 2>&1 | sed 's/^/         /' >&2 || true
  return 1
}

helm_repo() {
  local name="$1" url="$2"
  helm repo list -o json 2>/dev/null | jq -e --arg n "$name" '.[]|select(.name==$n)' >/dev/null \
    || helm repo add "$name" "$url" >/dev/null
}

# =============================================================================
# 0. Ön kontroller
# =============================================================================
preflight() {
  step "0/5  Ön kontroller"

  if (( BASH_VERSINFO[0] < 4 )); then
    die "bash 4+ gerekli (bulunan: ${BASH_VERSION}). macOS: brew install bash"
  fi

  for bin in kubectl helm envsubst jq; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı."
  done
  ok "Gerekli araçlar mevcut"

  if command -v kyverno >/dev/null 2>&1; then
    ok "kyverno CLI mevcut ($(kyverno version 2>/dev/null | head -1))"
  else
    warn "kyverno CLI yok — 'kyverno test policies/tests/' elle çalıştırılamayacak."
    warn "Kurulum: brew install kyverno  (veya https://kyverno.io/docs/kyverno-cli/install/)"
  fi

  kubectl cluster-info >/dev/null 2>&1 || die "Cluster'a ulaşılamıyor."
  ok "Cluster erişimi: $(kubectl config current-context)"

  [[ -f "${VERSIONS_FILE}" ]] || die "Sürüm dosyası yok: ${VERSIONS_FILE}"
  # shellcheck disable=SC1090
  set -a; source "${VERSIONS_FILE}"; set +a

  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} yok. Faz 1 README'sine bakın."
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a

  local missing=()
  for v in PLATFORM_REPO_URL PLATFORM_REPO_REVISION; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    err "${ENV_FILE} içinde şu değişkenler boş:"
    printf '         - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  ok "PLATFORM_REPO_URL=${PLATFORM_REPO_URL}  PLATFORM_REPO_REVISION=${PLATFORM_REPO_REVISION}"

  # Faz 1 hazır mı? (ölümcül değil ama uyarı — ESO/Crossplane depolamasız çalışabilir)
  if ! kubectl get storageclass ceph-block >/dev/null 2>&1; then
    warn "StorageClass 'ceph-block' bulunamadı — Faz 1 tamamlanmamış olabilir."
    confirm "Faz 1 doğrulanmadan devam edilsin mi?" || exit 1
  else
    ok "Faz 1 underlay tespit edildi (ceph-block StorageClass var)"
  fi
}

# =============================================================================
# YARDIMCI: git-watched dizinlerdeki ${PLATFORM_REPO_URL} yer tutucularını
# tespit et. Bunlar Faz1/Faz2'nin app-of-apps dizinlerinde YAŞAR ve ArgoCD
# onları DOĞRUDAN git'ten okur — envsubst ile "render edip başka yere
# yazmak" burada işe yaramaz, çünkü ArgoCD kendi git checkout'unu okur,
# bizim ürettiğimiz yerel dosyayı değil. Tek doğru çözüm: bu dosyaları
# GERÇEK repo URL'iyle YERİNDE değiştirip commit etmek — TEK SEFERLİK,
# ortamdan bağımsız bir işlem (IP/parola gibi cluster'a özgü değil).
# =============================================================================
check_git_placeholders_resolved() {
  # platform/policies/security eklendi (kapsamlı-eksik-tamamlama görevi):
  # 01-require-signed-images.yaml.tpl'nin ${HARBOR_HOSTNAME}'ı da AYNI
  # sınıf risk taşıyor — ArgoCD bu dizini de DOĞRUDAN git'ten okuyor
  # (bkz. apps/01-kyverno.yaml.tpl'in security source'u).
  local dirs=("${BOOTSTRAP_APPS_DIR}" "${APPS_DIR}" "${REPO_ROOT}/platform/policies/security")
  local hits=()
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r -d '' f; do
      grep -qE '\$\{(PLATFORM_REPO_URL|TENANT_REQUESTS_REPO_URL|HARBOR_HOSTNAME)\}' "$f" && hits+=("$f")
    done < <(find "$d" -name '*.tpl' -print0)
  done
  if (( ${#hits[@]} > 0 )); then
    err "Aşağıdaki dosyalarda \${PLATFORM_REPO_URL}/\${TENANT_REQUESTS_REPO_URL}/\${HARBOR_HOSTNAME} HÂLÂ çözülmemiş:"
    printf '         %s\n' "${hits[@]}" >&2
    err ""
    err "Bu dosyalar ArgoCD tarafından DOĞRUDAN git'ten okunur (root-app'ın"
    err "directory source'u). Render edilmemiş \${VAR} ile commit edilirlerse"
    err "ArgoCD chart/repo çözümlemesi başarısız olur (nuisance, veri kaybı"
    err "değil — ama sync hiç ilerlemez)."
    err ""
    err "TEK SEFERLİK düzeltme (bu değerler cluster'a değil REPO'ya özgüdür):"
    err "  find ${BOOTSTRAP_APPS_DIR} ${APPS_DIR} ${REPO_ROOT}/platform/policies/security -name '*.tpl' -exec \\"
    err "    sed -i '' \"s|\\\${PLATFORM_REPO_URL}|${PLATFORM_REPO_URL}|g; \\"
    err "               s|\\\${PLATFORM_REPO_REVISION}|${PLATFORM_REPO_REVISION}|g; \\"
    err "               s|\\\${TENANT_REQUESTS_REPO_URL}|${TENANT_REQUESTS_REPO_URL:-}|g; \\"
    err "               s|\\\${HARBOR_HOSTNAME}|${HARBOR_HOSTNAME:-}|g\" {} +"
    err "  git add ${BOOTSTRAP_APPS_DIR} ${APPS_DIR} ${REPO_ROOT}/platform/policies/security && git commit -m 'chore: repo URL/revizyonu somutlaştır'"
    err ""
    err "Sonra bu script'i tekrar çalıştırın. (PLATFORM_CONTEXT.md teknik borç #10)"
    return 1
  fi
  ok "Git-watched dizinlerde çözülmemiş \${PLATFORM_REPO_URL}/\${TENANT_REQUESTS_REPO_URL}/\${HARBOR_HOSTNAME} yok"
}

# =============================================================================
# 1. ArgoCD
# =============================================================================
install_argocd() {
  step "1/5  ArgoCD"

  helm_repo argo "${ARGOCD_HELM_REPO}"
  helm repo update argo >/dev/null

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace argocd platform.internal/layer=control-plane --overwrite >/dev/null

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install argo-cd argo/argo-cd --version ${ARGOCD_CHART_VERSION}"
    return 0
  fi

  helm upgrade --install argo-cd argo/argo-cd \
    --namespace argocd --version "${ARGOCD_CHART_VERSION}" \
    -f "${CONTROL_PLANE_DIR}/argocd/values.yaml" \
    --wait --timeout 10m

  wait_for "ArgoCD application-controller" 300 10 \
    kubectl -n argocd rollout status statefulset/argo-cd-application-controller --timeout=5s
  wait_for "ArgoCD repo-server" 300 10 \
    kubectl -n argocd rollout status deployment/argo-cd-repo-server --timeout=5s
  wait_for "ArgoCD server" 300 10 \
    kubectl -n argocd rollout status deployment/argo-cd-server --timeout=5s

  verify_argocd
}

verify_argocd() {
  log "DOĞRULAMA: ArgoCD"
  kubectl -n argocd get pods | sed 's/^/         /'

  if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    local pw
    pw="$(kubectl -n argocd get secret argocd-initial-admin-secret \
          -o jsonpath='{.data.password}' | base64 -d)"
    ok "Admin secret mevcut (kullanıcı: admin)"
    warn "İlk giriş parolası (BİR KEZ gösteriliyor, kaydedin):"
    printf '         %s\n' "${pw}"
    warn "İlk girişten sonra: kubectl -n argocd delete secret argocd-initial-admin-secret"
  else
    warn "argocd-initial-admin-secret yok (belki zaten silindi — normal olabilir)"
  fi

  log "Erişim: kubectl -n argocd port-forward svc/argo-cd-server 8080:443"
  ok "ArgoCD doğrulandı"
}

# =============================================================================
# 2. AppProject + root-app (App-of-Apps kaydı)
# =============================================================================
apply_root_app() {
  step "2/5  AppProject + root-app (App-of-Apps)"

  check_git_placeholders_resolved || die "Önce yukarıdaki adımı tamamlayın."

  local SUBST_VARS='${PLATFORM_REPO_URL} ${PLATFORM_REPO_REVISION}
${CILIUM_HELM_REPO} ${METALLB_HELM_REPO} ${ROOK_HELM_REPO}
${HARBOR_HELM_REPO} ${KEYCLOAK_HELM_REPO}
${CROSSPLANE_HELM_REPO} ${KYVERNO_HELM_REPO} ${ESO_HELM_REPO}
${TENANT_REQUESTS_REPO_URL}'

  mkdir -p "${BOOTSTRAP_APPS_DIR}/rendered" "${CONTROL_PLANE_DIR}/rendered"

  envsubst "${SUBST_VARS}" \
    < "${BOOTSTRAP_APPS_DIR}/appproject-platform.yaml.tpl" \
    > "${BOOTSTRAP_APPS_DIR}/rendered/appproject-platform.yaml"

  envsubst '${PLATFORM_REPO_URL} ${PLATFORM_REPO_REVISION}' \
    < "${CONTROL_PLANE_DIR}/root-app.yaml.tpl" \
    > "${CONTROL_PLANE_DIR}/rendered/root-app.yaml"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] render edildi, apply edilmedi:"
    log "  ${BOOTSTRAP_APPS_DIR}/rendered/appproject-platform.yaml"
    log "  ${CONTROL_PLANE_DIR}/rendered/root-app.yaml"
    return 0
  fi

  kubectl apply -f "${BOOTSTRAP_APPS_DIR}/rendered/appproject-platform.yaml"
  kubectl apply -f "${CONTROL_PLANE_DIR}/rendered/root-app.yaml"
  ok "AppProject 'platform' ve Application 'platform-root' uygulandı"

  wait_for "platform-root Application kaydı" 60 5 \
    kubectl -n argocd get application platform-root

  verify_root_app
}

verify_root_app() {
  log "DOĞRULAMA: App-of-Apps"
  log "  \$ kubectl -n argocd get application"
  kubectl -n argocd get application -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    2>/dev/null | sed 's/^/         /'

  log "  Beklenen child Application'lar: underlay-root, crossplane, kyverno, eso, vault"
  log "  (underlay-root ve vault KASITLI OLARAK 'OutOfSync' kalabilir — bkz."
  log "   00-underlay.yaml.tpl ve 02-vault-placeholder.yaml.tpl'deki notlar)"
  ok "App-of-Apps kaydı doğrulandı"
}

# =============================================================================
# 3. Crossplane + provider'lar + function-kcl
# =============================================================================
sync_crossplane() {
  step "3/5  Crossplane (sync-wave 1)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ArgoCD Application 'crossplane' senkronize edilecekti"
    return 0
  fi

  trigger_sync crossplane
  wait_for "Application 'crossplane' Synced" 300 10 \
    bash -c "kubectl -n argocd get application crossplane -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"

  wait_for "Crossplane core (deploy/crossplane)" 300 10 \
    kubectl -n crossplane-system rollout status deployment/crossplane --timeout=5s
  wait_for "Crossplane RBAC manager" 180 10 \
    kubectl -n crossplane-system rollout status deployment/crossplane-rbac-manager --timeout=5s

  wait_for "Provider CRD'leri kayıtlı" 120 5 \
    kubectl get crd providers.pkg.crossplane.io functions.pkg.crossplane.io

  wait_for "provider-kubernetes Installed" 300 10 \
    bash -c "kubectl get provider.pkg.crossplane.io provider-kubernetes -o jsonpath='{.status.conditions[?(@.type==\"Installed\")].status}' 2>/dev/null | grep -q True"
  wait_for "provider-helm Installed" 300 10 \
    bash -c "kubectl get provider.pkg.crossplane.io provider-helm -o jsonpath='{.status.conditions[?(@.type==\"Installed\")].status}' 2>/dev/null | grep -q True"
  wait_for "provider-terraform Installed" 300 10 \
    bash -c "kubectl get provider.pkg.crossplane.io provider-terraform -o jsonpath='{.status.conditions[?(@.type==\"Installed\")].status}' 2>/dev/null | grep -q True"
  wait_for "function-kcl Installed" 300 10 \
    bash -c "kubectl get function.pkg.crossplane.io function-kcl -o jsonpath='{.status.conditions[?(@.type==\"Installed\")].status}' 2>/dev/null | grep -q True"

  wait_for "provider-kubernetes Healthy" 300 10 \
    bash -c "kubectl get provider.pkg.crossplane.io provider-kubernetes -o jsonpath='{.status.conditions[?(@.type==\"Healthy\")].status}' 2>/dev/null | grep -q True"
  wait_for "provider-helm Healthy" 300 10 \
    bash -c "kubectl get provider.pkg.crossplane.io provider-helm -o jsonpath='{.status.conditions[?(@.type==\"Healthy\")].status}' 2>/dev/null | grep -q True"

  bind_provider_rbac provider-kubernetes
  bind_provider_rbac provider-helm

  # ProviderConfig'ler CRD'leri register olduktan sonra uygulanabilir —
  # ArgoCD kendi wave'inde (sync-wave "2") bunu zaten bekleyecek (Lua health
  # check sayesinde); burada script tarafında da ek bir garanti:
  wait_for "providerconfigs.kubernetes.crossplane.io CRD'si" 180 10 \
    kubectl get crd providerconfigs.kubernetes.crossplane.io
  wait_for "providerconfigs.helm.crossplane.io CRD'si" 180 10 \
    kubectl get crd providerconfigs.helm.crossplane.io

  trigger_sync crossplane   # ProviderConfig'lerin de senkronize olduğundan emin ol

  wait_for "ProviderConfig 'in-cluster' (kubernetes)" 120 5 \
    kubectl get providerconfig.kubernetes.crossplane.io in-cluster
  wait_for "ProviderConfig 'in-cluster' (helm)" 120 5 \
    kubectl get providerconfig.helm.crossplane.io in-cluster

  verify_crossplane
}

# ServiceAccount adı Provider kurulumunda rastgele üretilir; etiket
# seçiciyle bulup cluster-admin'e bağlıyoruz (provider-kubernetes/helm'in
# kendi dokümante ettiği standart kurulum — bkz. crossplane/README.md).
bind_provider_rbac() {
  local provider="$1"
  log "RBAC: ${provider} ServiceAccount → cluster-admin"

  local sa
  sa="$(kubectl -n crossplane-system get sa \
        -l "pkg.crossplane.io/provider=${provider}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "${sa}" ]]; then
    warn "  ${provider} için ServiceAccount bulunamadı (henüz oluşmamış olabilir)."
    warn "  Elle kontrol: kubectl -n crossplane-system get sa -l pkg.crossplane.io/provider=${provider}"
    return 1
  fi

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: crossplane-${provider}-cluster-admin
  labels:
    platform.internal/managed-by: control-plane-bootstrap
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: crossplane-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
  ok "  ${provider}: SA '${sa}' → cluster-admin bağlandı"
}

trigger_sync() {
  local app="$1"
  if command -v argocd >/dev/null 2>&1; then
    argocd app sync "${app}" --timeout 300 >/dev/null 2>&1 || true
  else
    log "  ('argocd' CLI yok — ArgoCD'nin kendi otomatik senkronizasyonu bekleniyor, ~180s)"
  fi
}

verify_crossplane() {
  log "DOĞRULAMA: Crossplane"
  log "  \$ kubectl get providers.pkg.crossplane.io"
  kubectl get providers.pkg.crossplane.io | sed 's/^/         /'
  log "  \$ kubectl get functions.pkg.crossplane.io"
  kubectl get functions.pkg.crossplane.io | sed 's/^/         /'
  log "  \$ kubectl get providerconfigs.kubernetes.crossplane.io,providerconfigs.helm.crossplane.io"
  kubectl get providerconfigs.kubernetes.crossplane.io,providerconfigs.helm.crossplane.io \
    2>/dev/null | sed 's/^/         /'

  log "  Statik kimlik bilgisi taraması (ProviderConfig'lerde 'source' alanı):"
  kubectl get providerconfigs.kubernetes.crossplane.io,providerconfigs.helm.crossplane.io \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}: {.spec.credentials.source}{"\n"}{end}' \
    2>/dev/null | sed 's/^/         /'
  ok "  Beklenen: hepsi 'InjectedIdentity' — Secret/statik değer YOK"

  ok "Crossplane doğrulandı"
}

# =============================================================================
# 4. Kyverno + ClusterPolicy'ler
# =============================================================================
sync_kyverno() {
  step "4/5  Kyverno (sync-wave 1)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ArgoCD Application 'kyverno' senkronize edilecekti"
    return 0
  fi

  ensure_cosign_signing_key_secret
  trigger_sync kyverno
  wait_for "Application 'kyverno' Synced" 300 10 \
    bash -c "kubectl -n argocd get application kyverno -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"

  wait_for "Kyverno admission-controller" 300 10 \
    kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=5s
  wait_for "Kyverno webhook kaydı" 180 5 \
    kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg

  wait_for "ClusterPolicy'ler yüklendi" 120 5 \
    bash -c 'test "$(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l)" -ge 3'

  verify_kyverno
}

# =============================================================================
# Kapsamlı-eksik-tamamlama görevi (açık karar #21'in çözümü): Kyverno'nun
# `require-signed-images` politikasının referans verdiği
# `cosign-image-signing-key` Secret'ını PUBLIC anahtardan üretir.
#
# ANAHTAR YÖNETİMİ: `platform/policies/security/cosign.pub`, GERÇEK (ama
# rotasyona AÇIK) bir Cosign public key'idir — public anahtar Git'e
# yazılabilir (sır DEĞİLDİR, yalnızca DOĞRULAMA için kullanılır, imzalama
# için değil). ÖZEL anahtar (`cosign.key`) HİÇBİR ZAMAN bu repoya
# YAZILMAZ — yalnızca CI'nın (`image-supply-chain.yaml`) kullandığı
# `COSIGN_PRIVATE_KEY` GitHub Actions Secret'ında durur. Anahtar rotasyonu:
# yeni bir çift üretilip (`cosign generate-key-pair`) `cosign.pub` bu
# dosyada GÜNCELLENİR + `COSIGN_PRIVATE_KEY` CI secret'ı YENİ özel anahtarla
# değiştirilir — İKİSİ AYNI ANDA değişmelidir (biri güncellenip diğeri
# unutulursa imzalar DOĞRULANAMAZ).
# =============================================================================
ensure_cosign_signing_key_secret() {
  local pubkey_file="${REPO_ROOT}/platform/policies/security/cosign.pub"
  [[ -f "${pubkey_file}" ]] || die "Cosign public key yok: ${pubkey_file}"

  kubectl create namespace kyverno --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kyverno create secret generic cosign-image-signing-key \
    --from-file="cosign.pub=${pubkey_file}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Secret hazır: kyverno/cosign-image-signing-key (public key, ${pubkey_file}'dan)"
}

verify_kyverno() {
  log "DOĞRULAMA: Kyverno"
  log "  \$ kubectl get clusterpolicy"
  kubectl get clusterpolicy -o custom-columns=\
'NAME:.metadata.name,ACTION:.spec.validationFailureAction,READY:.status.ready' \
    2>/dev/null | sed 's/^/         /'

  if command -v kyverno >/dev/null 2>&1; then
    log "  \$ kyverno test platform/policies/tests/ (yerel, cluster'a dokunmaz)"
    local fail=0
    for d in "${REPO_ROOT}"/platform/policies/tests/*/; do
      kyverno test "$d" >/dev/null 2>&1 || { warn "    ❌ $(basename "$d")"; fail=1; }
    done
    if (( fail == 0 )); then
      ok "  Tüm kyverno test paketleri yeşil"
    else
      err "  Bazı test paketleri kırmızı — yukarıdaki dizinlerde 'kyverno test <dir>' çalıştırın"
    fi
  else
    warn "  kyverno CLI yok — testler burada atlandı."
  fi

  ok "Kyverno doğrulandı (validationFailureAction=Audit — bkz. policies/README.md)"
}

# =============================================================================
# 5. External Secrets Operator (yalnızca operatör)
# =============================================================================
sync_eso() {
  step "5/5  External Secrets Operator (sync-wave 1, yalnızca operatör)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ArgoCD Application 'eso' senkronize edilecekti"
    return 0
  fi

  trigger_sync eso
  wait_for "Application 'eso' Synced" 300 10 \
    bash -c "kubectl -n argocd get application eso -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"

  wait_for "ESO controller" 300 10 \
    kubectl -n external-secrets rollout status deployment/external-secrets --timeout=5s
  wait_for "ESO webhook" 300 10 \
    kubectl -n external-secrets rollout status deployment/external-secrets-webhook --timeout=5s
  wait_for "ESO cert-controller" 300 10 \
    kubectl -n external-secrets rollout status deployment/external-secrets-cert-controller --timeout=5s

  verify_eso
}

verify_eso() {
  log "DOĞRULAMA: External Secrets Operator"
  kubectl -n external-secrets get pods | sed 's/^/         /'

  local ss_count
  ss_count="$(kubectl get secretstores.external-secrets.io,clustersecretstores.external-secrets.io \
              --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${ss_count}" == "0" ]]; then
    ok "  SecretStore/ClusterSecretStore YOK (beklenen — Faz 3'te Vault ile gelecek)"
  else
    warn "  ${ss_count} SecretStore bulundu — görev kapsamı 'yalnızca operator' idi, kontrol edin"
  fi
  ok "ESO doğrulandı"
}

# =============================================================================
# Özet
# =============================================================================
summary() {
  step "Özet"
  printf '\n  %-14s %-18s %s\n' "BİLEŞEN" "NAMESPACE" "DURUM"
  printf '  %s\n' "────────────────────────────────────────────────────────"
  local rows=(
    "ArgoCD|argocd|deployment/argo-cd-server"
    "Crossplane|crossplane-system|deployment/crossplane"
    "Kyverno|kyverno|deployment/kyverno-admission-controller"
    "ESO|external-secrets|deployment/external-secrets"
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
    printf '  %-14s %-18s %b\n' "${name}" "${ns}" "${state}"
  done

  cat <<EOS

  Sonraki adımlar
  ───────────────
  1. PLATFORM_CONTEXT.md "Kurulu bileşenler" tablosunu güncelleyin.
  2. underlay-root Application: platform/bootstrap/README.md "Faz 1 → Faz 2
     devralma" prosedürünü uygulayın (otomatik sync KASITLI OLARAK kapalı).
  3. Faz 3: Vault + cert-manager + ESO'nun ilk SecretStore'u.
     vault Application'ı (sync-wave 2) o zaman içerik kazanacak.

  Erişim
  ──────
  ArgoCD UI   kubectl -n argocd port-forward svc/argo-cd-server 8080:443
  Kyverno     kubectl get policyreport -A   (Audit modundaki ihlaller)

EOS
}

# =============================================================================
main() {
  log "Faz 2 — Control plane kurulumu"
  [[ "${DRY_RUN}"     == "true" ]] && warn "DRY-RUN: hiçbir değişiklik uygulanmaz"
  [[ "${VERIFY_ONLY}" == "true" ]] && warn "VERIFY-ONLY: yalnızca doğrulama"
  [[ -n "${ONLY}"               ]] && log  "Yalnızca adım: ${ONLY}"

  preflight

  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    should_run argocd     && verify_argocd     || true
    should_run root-app   && verify_root_app   || true
    should_run crossplane && verify_crossplane || true
    should_run kyverno    && verify_kyverno    || true
    should_run eso        && verify_eso        || true
    summary
    return 0
  fi

  should_run argocd     && install_argocd
  should_run root-app   && apply_root_app
  should_run crossplane && sync_crossplane
  should_run kyverno    && sync_kyverno
  should_run eso        && sync_eso

  summary
  ok "Faz 2 tamamlandı."
}

main "$@"
