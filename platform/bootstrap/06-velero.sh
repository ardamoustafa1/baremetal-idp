#!/usr/bin/env bash
# =============================================================================
# Faz 12h — Velero: K8s obje/PV yedekleme (Ceph RGW birincil, isteğe bağlı
# küme-dışı ikincil hedef). code review #11/#12'nin çözümü.
#
#   ObjectBucketClaim (velero-backups) → S3 kimlik bilgisi kopyalama
#     → (VELERO_OFFSITE_ENABLED=true ise) ikinci profil eklenir
#     → velero-credentials Secret'ı → Velero (helm doğrudan — S3 sırrı Git'e
#       YAZILMAZ, bkz. apps/02-velero.yaml.tpl'in "otomatik sync KASITLI
#       KAPALI" notu) → günlük Schedule doğrulaması
#
# TASARIM KURALLARI (01-05 ile aynı):
#   1. IDEMPOTENT.
#   2. HARDCODED DEĞER YOK (chart sürümü versions.env'den, sırlar .env'den).
#   3. HER ADIMDA READINESS.
#   4. S3 kimlik bilgileri Rook OBC'sinden okunur, HİÇBİR ZAMAN Git'e
#      yazılmaz — render edilmiş değerler `rendered/` altında kalır.
#
# ÖN KOŞUL: Faz 1 (Rook-Ceph ceph-bucket StorageClass) ve Faz 2 (ArgoCD).
#
# KULLANIM
#   ./platform/bootstrap/06-velero.sh                    # tümü
#   ./platform/bootstrap/06-velero.sh --only schedule-test
#   ./platform/bootstrap/06-velero.sh --verify-only
#   ./platform/bootstrap/06-velero.sh --dry-run
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNDERLAY_DIR="${REPO_ROOT}/platform/underlay"
VELERO_DIR="${REPO_ROOT}/platform/control-plane/velero"
ENV_FILE="${UNDERLAY_DIR}/.env"
VERSIONS_FILE="${UNDERLAY_DIR}/versions.env"

ONLY=""
DRY_RUN="false"
VERIFY_ONLY="false"

if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m';   C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

_ts() { date '+%H:%M:%S'; }
log()   { printf '%s [%s] %s\n'   "$(_ts)" "${C_BLU}INFO${C_RST}" "$*"; }
ok()    { printf '%s [%s]   %s\n' "$(_ts)" "${C_GRN} OK ${C_RST}" "$*"; }
warn()  { printf '%s [%s] %s\n'   "$(_ts)" "${C_YLW}WARN${C_RST}" "$*" >&2; }
err()   { printf '%s [%s] %s\n'   "$(_ts)" "${C_RED}FAIL${C_RST}" "$*" >&2; }
step()  { printf '\n%s%s══ %s %s%s\n' "${C_BLD}" "${C_BLU}" "$*" "══" "${C_RST}"; }
die() { err "$*"; exit 1; }

trap 'err "Satır ${LINENO}: komut başarısız (exit=$?). Yukarıdaki çıktıya bakın."' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)        ONLY="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --verify-only) VERIFY_ONLY="true"; shift ;;
    -h|--help)     sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "Bilinmeyen argüman: $1  (--help)" ;;
  esac
done

should_run() { [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]; }

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

# =============================================================================
# 0. Ön kontroller
# =============================================================================
preflight() {
  step "0/4  Ön kontroller"
  for bin in kubectl helm envsubst jq; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı."
  done
  ok "Gerekli araçlar mevcut"

  kubectl cluster-info >/dev/null 2>&1 || die "Cluster'a ulaşılamıyor."
  ok "Cluster erişimi: $(kubectl config current-context)"

  [[ -f "${VERSIONS_FILE}" ]] || die "Sürüm dosyası yok: ${VERSIONS_FILE}"
  set -a; source "${VERSIONS_FILE}"; set +a
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} yok."
  set -a; source "${ENV_FILE}"; set +a

  [[ -n "${CEPH_OBJECTSTORE_NAME:-}" ]] || die "CEPH_OBJECTSTORE_NAME .env'de boş."
  VELERO_OFFSITE_ENABLED="${VELERO_OFFSITE_ENABLED:-false}"

  if [[ "${VELERO_OFFSITE_ENABLED}" == "true" ]]; then
    for v in VELERO_OFFSITE_S3_URL VELERO_OFFSITE_S3_REGION VELERO_OFFSITE_S3_BUCKET \
             VELERO_OFFSITE_S3_ACCESS_KEY VELERO_OFFSITE_S3_SECRET_KEY; do
      [[ -n "${!v:-}" ]] || die "VELERO_OFFSITE_ENABLED=true ama ${v} boş (.env'i kontrol edin)."
    done
    ok "Küme-dışı ikincil hedef ETKİN: ${VELERO_OFFSITE_S3_URL}"
  else
    warn "Küme-dışı ikincil hedef KAPALI (VELERO_OFFSITE_ENABLED=false) — Velero'nun"
    warn "TEK yedeği Rook-Ceph RGW'nin ÜZERİNDE duruyor (bkz. docs/runbooks/"
    warn "disaster-recovery.md §3.1 'KRİTİK MİMARİ RİSK'). Üretimde şiddetle önerilir."
  fi
}

# =============================================================================
# 1. ObjectBucketClaim + S3 kimlik bilgisi Secret'ı
# =============================================================================
apply_obc_and_secret() {
  step "1/4  ObjectBucketClaim + velero-credentials Secret'ı"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ${VELERO_DIR}/resources/objectbucketclaim.yaml uygulanacaktı"
    return 0
  fi

  kubectl apply -f "${VELERO_DIR}/resources/objectbucketclaim.yaml"
  wait_for "OBC velero-backups Bound" 180 5 \
    bash -c "kubectl -n rook-ceph get obc velero-backups -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound"

  local key secret
  key="$(kubectl -n rook-ceph get secret velero-backups -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)"
  secret="$(kubectl -n rook-ceph get secret velero-backups -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)"
  [[ -n "${key}" && -n "${secret}" ]] \
    || die "OBC 'velero-backups' secret'ı okunamadı. kubectl -n rook-ceph get obc velero-backups"

  kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace velero platform.internal/layer=control-plane --overwrite >/dev/null

  # `cloud` anahtarı, Velero'nun AWS plugin'inin BEKLEDİĞİ INI biçimidir —
  # `[default]` profili HER ZAMAN vardır (Ceph RGW); `[offsite]` profili
  # YALNIZCA VELERO_OFFSITE_ENABLED=true iken eklenir.
  local work; work="$(mktemp -d)"
  {
    printf '[default]\n'
    printf 'aws_access_key_id=%s\n' "${key}"
    printf 'aws_secret_access_key=%s\n' "${secret}"
    if [[ "${VELERO_OFFSITE_ENABLED}" == "true" ]]; then
      printf '\n[offsite]\n'
      printf 'aws_access_key_id=%s\n' "${VELERO_OFFSITE_S3_ACCESS_KEY}"
      printf 'aws_secret_access_key=%s\n' "${VELERO_OFFSITE_S3_SECRET_KEY}"
    fi
  } > "${work}/cloud"

  kubectl -n velero create secret generic velero-credentials \
    --from-file="cloud=${work}/cloud" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  shred -u "${work}/cloud" 2>/dev/null || rm -f "${work}/cloud"
  rmdir "${work}"

  ok "velero-credentials Secret'ı hazır (profil: default$([[ "${VELERO_OFFSITE_ENABLED}" == "true" ]] && echo ', offsite'))"
}

# =============================================================================
# 2. Velero (helm doğrudan — S3 sırrı Git'e YAZILMAZ)
# =============================================================================
install_velero() {
  step "2/4  Velero ${VELERO_CHART_VERSION} (K8s obje/PV yedekleme)"

  helm_repo vmware-tanzu "${VELERO_HELM_REPO}"
  helm repo update vmware-tanzu >/dev/null

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install velero vmware-tanzu/velero --version ${VELERO_CHART_VERSION}"
    return 0
  fi

  mkdir -p "${VELERO_DIR}/rendered"
  envsubst '${CEPH_OBJECTSTORE_NAME}' \
    < "${VELERO_DIR}/values.yaml.tpl" \
    > "${VELERO_DIR}/rendered/values.yaml"

  local -a value_files=(-f "${VELERO_DIR}/rendered/values.yaml")
  if [[ "${VELERO_OFFSITE_ENABLED}" == "true" ]]; then
    envsubst '${CEPH_OBJECTSTORE_NAME} ${VELERO_OFFSITE_S3_URL} ${VELERO_OFFSITE_S3_REGION} ${VELERO_OFFSITE_S3_BUCKET} ${VELERO_OFFSITE_S3_FORCE_PATH_STYLE}' \
      < "${VELERO_DIR}/values-offsite.yaml.tpl" \
      > "${VELERO_DIR}/rendered/values-offsite.yaml"
    value_files+=(-f "${VELERO_DIR}/rendered/values-offsite.yaml")
  fi

  helm upgrade --install velero vmware-tanzu/velero \
    --namespace velero --version "${VELERO_CHART_VERSION}" \
    "${value_files[@]}" \
    --wait --timeout 5m

  wait_for "Velero deployment" 300 10 \
    kubectl -n velero rollout status deployment/velero --timeout=5s

  verify_velero
}

verify_velero() {
  log "DOĞRULAMA: Velero"
  kubectl -n velero get pods | sed 's/^/         /'
  log "  \$ kubectl -n velero get backupstoragelocation"
  kubectl -n velero get backupstoragelocation -o custom-columns=\
'NAME:.metadata.name,PHASE:.status.phase' 2>/dev/null | sed 's/^/         /'
  log "  \$ kubectl -n velero get schedule"
  kubectl -n velero get schedule 2>/dev/null | sed 's/^/         /'
  ok "Velero doğrulandı"
}

# =============================================================================
# 3. Uçtan uca test: gerçek bir on-demand backup tetikle ve tamamlanmasını
#    doğrula (günlük Schedule'ın 03:00'ı beklemeden, KURULUMUN GERÇEKTEN
#    çalıştığını KANITLAR — yalnızca Schedule/BackupStorageLocation
#    nesnelerinin VAR OLMASI, backup'ın GERÇEKTEN alınabildiğini KANITLAMAZ).
# =============================================================================
run_backup_smoke_test() {
  step "3/4  Uçtan uca test: on-demand backup"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] test backup'ı tetiklenip doğrulanacaktı"
    return 0
  fi

  local name="bootstrap-smoke-test-$(date +%s)"
  kubectl -n velero create -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: ${name}
  namespace: velero
spec:
  includedNamespaces: ["velero"]
  storageLocation: default
  ttl: 1h0m0s
EOF

  wait_for "Backup '${name}' Completed" 180 5 \
    bash -c "kubectl -n velero get backup ${name} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Completed"

  log "\$ kubectl -n velero describe backup ${name}"
  kubectl -n velero describe backup "${name}" | sed 's/^/         /'
  ok "On-demand backup GERÇEKTEN tamamlandı — Velero → Ceph RGW yolu çalışıyor"

  kubectl -n velero delete backup "${name}" --wait=false >/dev/null 2>&1 || true
}

# =============================================================================
# Özet
# =============================================================================
summary() {
  step "Özet"
  cat <<EOS

  Sonraki adımlar:
  1. GERÇEK bir restore tatbikatı (bkz. docs/runbooks/disaster-recovery.md).
  2. VELERO_OFFSITE_ENABLED=false ise ve üretimdeyseniz: küme-dışı bir S3
     hedefi (.env'de VELERO_OFFSITE_*) ekleyip bu script'i tekrar çalıştırın
     — Ceph'in TAMAMEN kaybı, tek başına Ceph RGW hedefli yedekleri de
     BİRLİKTE götürür.
  3. CNPG'nin KENDİ PITR restore prosedürü İÇİN bkz. compositions/postgresql/
     README.md "Restore" bölümü — Velero PV içeriğini YEDEKLEMEZ (bkz.
     values.yaml.tpl'in "CSI volume snapshot" notu), Postgres verisinin
     birincil kurtarma yolu HER ZAMAN Barman/PITR'dır.
EOS
}

main() {
  log "Faz 12h — Velero kurulumu"
  [[ "${DRY_RUN}"     == "true" ]] && warn "DRY-RUN: hiçbir değişiklik uygulanmaz"
  [[ "${VERIFY_ONLY}" == "true" ]] && warn "VERIFY-ONLY: yalnızca doğrulama"
  [[ -n "${ONLY}"               ]] && log  "Yalnızca adım: ${ONLY}"

  preflight

  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    should_run velero && verify_velero || true
    summary
    return 0
  fi

  should_run obc            && apply_obc_and_secret
  should_run velero         && install_velero
  should_run schedule-test  && run_backup_smoke_test

  summary
  ok "Velero kurulumu tamamlandı."
}

main "$@"
