#!/usr/bin/env bash
# =============================================================================
# Faz 9 — Gözlemlenebilirlik: kube-prometheus-stack + Loki + Tempo + OpenCost
#         + haftalık tenant özeti CronJob'u.
#
#   OBC'ler (loki-storage/tempo-storage) → S3 kimlik bilgisi kopyalama
#     → Grafana admin Secret'ı → Alertmanager routing Secret'ı (Slack/Teams)
#     → kube-prometheus-stack (ArgoCD, sync-wave 1)
#     → Loki + Tempo (helm doğrudan — S3 sırrı Git'e YAZILMAZ, bkz.
#       apps/01-loki.yaml.tpl'in "otomatik sync KASITLI KAPALI" notu)
#     → OpenCost custom-pricing ConfigMap → OpenCost (ArgoCD, sync-wave 2)
#     → weekly-report CronJob (script → ConfigMap, RBAC, CronJob)
#
# TASARIM KURALLARI (01/02/03/04 ile aynı):
#   1. IDEMPOTENT.
#   2. HARDCODED DEĞER YOK (chart sürümleri versions.env'den, sırlar .env'den).
#   3. HER ADIMDA READINESS.
#   4. Loki/Tempo'nun S3 kimlik bilgileri Rook OBC'sinden okunur, HİÇBİR
#      ZAMAN Git'e yazılmaz — render edilmiş değerler `rendered/` altında
#      kalır (.gitignore'da, underlay ile AYNI desen).
#
# ÖN KOŞUL: Faz 1 (Rook-Ceph ceph-bucket StorageClass) ve Faz 2 (ArgoCD)
# tamamlanmış olmalı.
#
# KULLANIM
#   ./platform/bootstrap/05-observability.sh                     # tümü
#   ./platform/bootstrap/05-observability.sh --only loki          # tek adım
#   ./platform/bootstrap/05-observability.sh --verify-only
#   ./platform/bootstrap/05-observability.sh --dry-run
#   ./platform/bootstrap/05-observability.sh --only cert-alert-test
#       # Kısa ömürlü test sertifikasıyla cert-manager expiry alert'inin
#       # UÇTAN UCA çalıştığını doğrular (bkz. verify_cert_expiry_alert).
#       # NOT: PrometheusRule'ün `for: 5m` şartı nedeniyle bu adım GERÇEKTEN
#       # birkaç dakika sürer — bu KASITLIDIR (kısayol yok).
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNDERLAY_DIR="${REPO_ROOT}/platform/underlay"
OBS_DIR="${REPO_ROOT}/platform/control-plane/observability"
OPENCOST_DIR="${REPO_ROOT}/platform/control-plane/opencost"
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
    -h|--help)     sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "Bilinmeyen argüman: $1  (--help)" ;;
  esac
done

should_run() { [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]; }

ensure_ns() {
  local ns="$1"
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace "$ns" \
    platform.internal/layer=control-plane \
    platform.internal/managed-by=observability-bootstrap \
    --overwrite >/dev/null
}

ensure_secret() {
  local ns="$1" name="$2"; shift 2
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  kubectl -n "$ns" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Secret hazır: ${ns}/${name}"
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

trigger_sync() {
  local app="$1"
  if command -v argocd >/dev/null 2>&1; then
    argocd app sync "${app}" --timeout 300 >/dev/null 2>&1 || true
  else
    log "  ('argocd' CLI yok — ArgoCD'nin kendi otomatik senkronizasyonu bekleniyor, ~180s)"
  fi
}

# =============================================================================
# 0. Ön kontroller
# =============================================================================
preflight() {
  step "0/8  Ön kontroller"

  (( BASH_VERSINFO[0] >= 4 )) || die "bash 4+ gerekli (bulunan: ${BASH_VERSION})."

  for bin in kubectl helm envsubst jq curl; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı."
  done
  ok "Gerekli araçlar mevcut"

  [[ -f "${VERSIONS_FILE}" ]] || die "Sürüm dosyası yok: ${VERSIONS_FILE}"
  # shellcheck disable=SC1090
  set -a; source "${VERSIONS_FILE}"; set +a
  [[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} yok."
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a

  local missing=()
  for v in GRAFANA_ADMIN_PASSWORD OPENCOST_CPU_HOURLY_COST OPENCOST_RAM_HOURLY_COST OPENCOST_STORAGE_HOURLY_COST; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} > 0 )); then
    err "${ENV_FILE} içinde şu değişkenler boş:"; printf '         - %s\n' "${missing[@]}" >&2
    exit 1
  fi
  [[ -n "${ALERTMANAGER_WEBHOOK_URL:-}" ]] \
    || warn "ALERTMANAGER_WEBHOOK_URL boş — Alertmanager Secret'ı yine de uygulanacak ama Slack/Teams'e bildirim GİTMEYECEK."
  case "${ALERTMANAGER_WEBHOOK_TYPE:-slack}" in
    slack|teams) ;;
    *) die "ALERTMANAGER_WEBHOOK_TYPE 'slack' veya 'teams' olmalı (bulunan: '${ALERTMANAGER_WEBHOOK_TYPE:-}')" ;;
  esac

  kubectl cluster-info >/dev/null 2>&1 || die "Cluster'a ulaşılamıyor."
  ok "Cluster erişimi: $(kubectl config current-context)"

  kubectl get storageclass ceph-block >/dev/null 2>&1 \
    || die "StorageClass 'ceph-block' yok — Faz 1 tamamlanmamış."
  kubectl get storageclass ceph-bucket >/dev/null 2>&1 \
    || die "StorageClass 'ceph-bucket' yok — Faz 1 tamamlanmamış."
  kubectl -n argocd get deployment argo-cd-server >/dev/null 2>&1 \
    || die "ArgoCD bulunamadı — Faz 2 tamamlanmamış."
  ok "Faz 1/2 ön koşulları doğrulandı"

  ensure_ns observability
  ensure_ns opencost
}

# =============================================================================
# 1. ObjectBucketClaim'ler (loki-storage, tempo-storage)
# =============================================================================
apply_obcs() {
  step "1/8  ObjectBucketClaim'ler (rook-ceph namespace)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ${OBS_DIR}/resources/objectbucketclaims.yaml uygulanacaktı"
    return 0
  fi

  kubectl apply -f "${OBS_DIR}/resources/objectbucketclaims.yaml"

  wait_for "OBC loki-storage Bound" 180 5 \
    bash -c "kubectl -n rook-ceph get obc loki-storage -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound"
  wait_for "OBC tempo-storage Bound" 180 5 \
    bash -c "kubectl -n rook-ceph get obc tempo-storage -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Bound"

  ok "OBC'ler hazır"
}

# S3 kimlik bilgilerini Rook OBC secret/configmap'inden okuyup dışa aktarır
# (Harbor'un 01-underlay.sh'teki AYNI deseni — bkz. PLATFORM_CONTEXT.md).
read_obc_s3() {
  local obc="$1" prefix="$2"
  local key secret host port
  key="$(kubectl -n rook-ceph get secret "${obc}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)"
  secret="$(kubectl -n rook-ceph get secret "${obc}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)"
  host="$(kubectl -n rook-ceph get configmap "${obc}" -o jsonpath='{.data.BUCKET_HOST}' 2>/dev/null || true)"
  port="$(kubectl -n rook-ceph get configmap "${obc}" -o jsonpath='{.data.BUCKET_PORT}' 2>/dev/null || true)"
  [[ -n "${key}" && -n "${secret}" ]] \
    || die "OBC '${obc}' secret'ı okunamadı. kubectl -n rook-ceph get obc ${obc}"
  export "${prefix}_S3_ACCESS_KEY=${key}"
  export "${prefix}_S3_SECRET_KEY=${secret}"
  export "${prefix}_S3_HOST=${host}"
  export "${prefix}_S3_PORT=${port:-80}"
}

# =============================================================================
# 2. Grafana admin Secret'ı + Alertmanager routing Secret'ı
# =============================================================================
apply_secrets() {
  step "2/8  Grafana admin + Alertmanager routing Secret'ları"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] grafana-admin-credentials ve alertmanager Secret'ı uygulanacaktı"
    return 0
  fi

  ensure_secret observability grafana-admin-credentials \
    "admin-user=admin" \
    "admin-password=${GRAFANA_ADMIN_PASSWORD}"

  mkdir -p "${OBS_DIR}/rendered"
  local tpl="${OBS_DIR}/resources/alertmanager-config-${ALERTMANAGER_WEBHOOK_TYPE:-slack}.yaml.tpl"
  [[ -f "${tpl}" ]] || die "Şablon yok: ${tpl}"

  local subst_vars
  if [[ "${ALERTMANAGER_WEBHOOK_TYPE:-slack}" == "teams" ]]; then
    subst_vars='${TEAMS_WEBHOOK_URL}'
    export TEAMS_WEBHOOK_URL="${ALERTMANAGER_WEBHOOK_URL:-}"
  else
    subst_vars='${SLACK_WEBHOOK_URL}'
    export SLACK_WEBHOOK_URL="${ALERTMANAGER_WEBHOOK_URL:-}"
  fi

  envsubst "${subst_vars}" < "${tpl}" > "${OBS_DIR}/rendered/alertmanager-secret.yaml"
  kubectl apply -f "${OBS_DIR}/rendered/alertmanager-secret.yaml"
  ok "Alertmanager routing Secret'ı uygulandı (tip: ${ALERTMANAGER_WEBHOOK_TYPE:-slack})"

  kubectl apply -f "${OBS_DIR}/resources/certmanager-expiry-rules.yaml"
  ok "cert-manager expiry PrometheusRule uygulandı"
}

# =============================================================================
# 3. kube-prometheus-stack (ArgoCD, sync-wave 1)
# =============================================================================
sync_kube_prometheus_stack() {
  step "3/8  kube-prometheus-stack (ArgoCD sync-wave 1)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] ArgoCD Application 'kube-prometheus-stack' senkronize edilecekti"
    return 0
  fi

  trigger_sync kube-prometheus-stack
  wait_for "Application 'kube-prometheus-stack' Synced" 300 10 \
    bash -c "kubectl -n argocd get application kube-prometheus-stack -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"

  wait_for "Prometheus statefulset" 300 10 \
    kubectl -n observability rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=5s
  wait_for "Alertmanager statefulset" 180 10 \
    kubectl -n observability rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=5s
  wait_for "Grafana deployment" 300 10 \
    kubectl -n observability rollout status deployment/kube-prometheus-stack-grafana --timeout=5s

  verify_kube_prometheus_stack
}

verify_kube_prometheus_stack() {
  log "DOĞRULAMA: kube-prometheus-stack"
  kubectl -n observability get pods -l app.kubernetes.io/part-of=kube-prometheus-stack | sed 's/^/         /'
  kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com >/dev/null 2>&1 \
    && ok "  ServiceMonitor/PrometheusRule CRD'leri mevcut (Cilium/cert-manager ServiceMonitor'ları artık geçerli)" \
    || warn "  ServiceMonitor/PrometheusRule CRD'leri henüz görünmüyor"
  ok "kube-prometheus-stack doğrulandı"
}

# =============================================================================
# 4. Loki  (helm doğrudan — S3 sırrı Git'e YAZILMAZ)
# =============================================================================
install_loki() {
  step "4/8  Loki ${LOKI_CHART_VERSION} (log depolama, S3: Ceph RGW)"

  helm repo list -o json 2>/dev/null | jq -e '.[]|select(.name=="grafana")' >/dev/null \
    || helm repo add grafana "${LOKI_HELM_REPO}" >/dev/null
  helm repo update grafana >/dev/null

  read_obc_s3 loki-storage LOKI

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install loki grafana/loki --version ${LOKI_CHART_VERSION}"
    return 0
  fi

  mkdir -p "${OBS_DIR}/rendered"
  envsubst '${LOKI_S3_ACCESS_KEY} ${LOKI_S3_SECRET_KEY} ${CEPH_OBJECTSTORE_NAME}' \
    < "${OBS_DIR}/loki/values.yaml.tpl" \
    > "${OBS_DIR}/rendered/loki-values.yaml"

  helm upgrade --install loki grafana/loki \
    --namespace observability --version "${LOKI_CHART_VERSION}" \
    -f "${OBS_DIR}/rendered/loki-values.yaml" \
    --wait --timeout 10m

  wait_for "Loki (singlebinary) hazır" 300 10 \
    kubectl -n observability rollout status statefulset/loki --timeout=5s

  verify_loki
}

verify_loki() {
  log "DOĞRULAMA: Loki"
  kubectl -n observability get pods -l app.kubernetes.io/name=loki | sed 's/^/         /'
  ok "Loki doğrulandı"
}

# =============================================================================
# 5. Tempo  (helm doğrudan — Loki ile AYNI gerekçe)
# =============================================================================
install_tempo() {
  step "5/8  Tempo ${TEMPO_CHART_VERSION} (trace depolama, S3: Ceph RGW)"

  helm repo list -o json 2>/dev/null | jq -e '.[]|select(.name=="grafana")' >/dev/null \
    || helm repo add grafana "${TEMPO_HELM_REPO}" >/dev/null
  helm repo update grafana >/dev/null

  read_obc_s3 tempo-storage TEMPO

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install tempo grafana/tempo --version ${TEMPO_CHART_VERSION}"
    return 0
  fi

  mkdir -p "${OBS_DIR}/rendered"
  envsubst '${TEMPO_S3_ACCESS_KEY} ${TEMPO_S3_SECRET_KEY} ${CEPH_OBJECTSTORE_NAME}' \
    < "${OBS_DIR}/tempo/values.yaml.tpl" \
    > "${OBS_DIR}/rendered/tempo-values.yaml"

  helm upgrade --install tempo grafana/tempo \
    --namespace observability --version "${TEMPO_CHART_VERSION}" \
    -f "${OBS_DIR}/rendered/tempo-values.yaml" \
    --wait --timeout 10m

  wait_for "Tempo hazır" 300 10 \
    kubectl -n observability rollout status statefulset/tempo --timeout=5s

  verify_tempo
}

verify_tempo() {
  log "DOĞRULAMA: Tempo"
  kubectl -n observability get pods -l app.kubernetes.io/name=tempo | sed 's/^/         /'
  ok "Tempo doğrulandı"
}

# =============================================================================
# 6. OpenCost (custom pricing ConfigMap + ArgoCD sync-wave 2)
# =============================================================================
sync_opencost() {
  step "6/8  OpenCost (bare-metal manuel fiyatlandırma, cost-center raporu)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] custom-pricing ConfigMap uygulanacak, ArgoCD 'opencost' senkronize edilecekti"
    return 0
  fi

  mkdir -p "${OPENCOST_DIR}/rendered"
  envsubst '${OPENCOST_CPU_HOURLY_COST} ${OPENCOST_RAM_HOURLY_COST} ${OPENCOST_STORAGE_HOURLY_COST}' \
    < "${OPENCOST_DIR}/resources/custom-pricing-configmap.yaml.tpl" \
    > "${OPENCOST_DIR}/rendered/custom-pricing-configmap.yaml"
  kubectl apply -f "${OPENCOST_DIR}/rendered/custom-pricing-configmap.yaml"
  ok "Custom pricing ConfigMap uygulandı (CPU=${OPENCOST_CPU_HOURLY_COST}/saat, RAM=${OPENCOST_RAM_HOURLY_COST}/saat)"

  trigger_sync opencost
  wait_for "Application 'opencost' Synced" 300 10 \
    bash -c "kubectl -n argocd get application opencost -o jsonpath='{.status.sync.status}' 2>/dev/null | grep -q Synced"
  wait_for "OpenCost deployment" 300 10 \
    kubectl -n opencost rollout status deployment/opencost --timeout=5s

  # OpenCost pod'u ConfigMap'i env'den okuyor — custom pricing ConfigMap'i
  # OpenCost'tan SONRA değiştiyse pod'un yeniden başlatılması gerekir.
  kubectl -n opencost rollout restart deployment/opencost >/dev/null 2>&1 || true

  verify_opencost
}

verify_opencost() {
  log "DOĞRULAMA: OpenCost"
  kubectl -n opencost get pods | sed 's/^/         /'
  log "  Cost-center bazlı rapor testi (kabul kriteri):"
  log "  \$ kubectl -n opencost port-forward svc/opencost 9003:9003"
  log "  \$ curl 'http://localhost:9003/allocation/compute?window=1d&aggregate=label:cost-center'"
  ok "OpenCost doğrulandı (manuel port-forward ile rapor gruplaması kontrol edilmeli)"
}

# =============================================================================
# 7. Haftalık tenant özeti CronJob'u
# =============================================================================
apply_weekly_report() {
  step "7/8  Haftalık tenant özeti (CronJob)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] weekly-report-script ConfigMap'i + cronjob.yaml uygulanacaktı"
    return 0
  fi

  # report.sh TEK doğruluk kaynağıdır — ConfigMap İÇERİĞİ HER ZAMAN bu
  # dosyadan üretilir (bkz. cronjob.yaml'daki "NOT" yorumu).
  kubectl -n observability create configmap weekly-report-script \
    --from-file=report.sh="${OBS_DIR}/weekly-report/report.sh" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f "${OBS_DIR}/weekly-report/cronjob.yaml"

  ok "weekly-tenant-report CronJob uygulandı (schedule: Pazartesi 06:00 UTC)"
  log "  Elle tetiklemek için: kubectl -n observability create job --from=cronjob/weekly-tenant-report manual-run-\$(date +%s)"
}

# =============================================================================
# 8. (opsiyonel) cert-manager expiry alert — uçtan uca test
#
# Kısa ömürlü (1h) bir test sertifikası, cert-manager expiry
# PrometheusRule'ünün gerçekten TETİKLENDİĞİNİ (yalnızca "syntax valid" değil)
# doğrular. `for: 5m` şartı nedeniyle bu adım GERÇEKTEN birkaç dakika sürer.
# =============================================================================
verify_cert_expiry_alert() {
  step "8/8  cert-manager expiry alert — uçtan uca test (birkaç dakika sürer)"

  local ns="observability-cert-alert-test"
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: expiry-alert-smoke-test
  namespace: ${ns}
spec:
  secretName: expiry-alert-smoke-test-tls
  # 1 saatlik ömür + hemen yenilenebilir olmayan bir renewBefore: metrik,
  # sertifikanın "1 gün içinde dolacak" (ve "30 gün içinde") eşiklerinin
  # HER İKİSİNİ DE anında sağlar (1h < 1 gün < 7 gün < 30 gün).
  duration: 1h
  renewBefore: 55m
  issuerRef:
    name: selfsigned-test-issuer
    kind: Issuer
  dnsNames:
    - expiry-alert-smoke-test.${ns}.svc.cluster.local
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-test-issuer
  namespace: ${ns}
spec:
  selfSigned: {}
EOF

  wait_for "Certificate expiry-alert-smoke-test Ready" 120 5 \
    bash -c "kubectl -n ${ns} get certificate expiry-alert-smoke-test -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q True"

  log "Prometheus'un metriği toplaması + PrometheusRule'ün 'for: 5m' şartı için bekleniyor..."
  log "(Prometheus port-forward: kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090)"

  wait_for "certmanager_certificate_expiration_timestamp_seconds metriği görünür" 180 10 \
    bash -c "kubectl -n observability exec deploy/kube-prometheus-stack-grafana -c grafana -- true 2>/dev/null; \
      kubectl run -n observability curl-expiry-check --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
      curl -s 'http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090/api/v1/query?query=certmanager_certificate_expiration_timestamp_seconds%7Bname%3D%22expiry-alert-smoke-test%22%7D' \
      | grep -q expiry-alert-smoke-test"

  wait_for "Alert 'CertificateExpiringIn1Day' Alertmanager'da FIRING" 420 15 \
    bash -c "kubectl run -n observability curl-alert-check --rm -i --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
      curl -s 'http://alertmanager-operated.observability.svc.cluster.local:9093/api/v2/alerts' \
      | grep -q CertificateExpiringIn1Day"

  ok "cert-manager expiry alert UÇTAN UCA doğrulandı (metrik → PrometheusRule → Alertmanager)"
  warn "Slack/Teams'e GERÇEKTEN gönderim, .env → ALERTMANAGER_WEBHOOK_URL'in GEÇERLİ olmasına bağlıdır — bu script webhook'un ALICI TARAFINI doğrulamaz."

  kubectl delete namespace "${ns}" --wait=false >/dev/null 2>&1 || true
  ok "Test namespace'i (${ns}) temizlendi"
}

# =============================================================================
# Özet
# =============================================================================
summary() {
  step "Özet"
  printf '\n  %-24s %-14s %s\n' "BİLEŞEN" "NAMESPACE" "DURUM"
  printf '  %s\n' "────────────────────────────────────────────────────────────────"
  local rows=(
    "kube-prometheus-stack|observability|statefulset/prometheus-kube-prometheus-stack-prometheus"
    "Grafana|observability|deployment/kube-prometheus-stack-grafana"
    "Loki|observability|statefulset/loki"
    "Tempo|observability|statefulset/tempo"
    "OpenCost|opencost|deployment/opencost"
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
    printf '  %-24s %-14s %b\n' "${name}" "${ns}" "${state}"
  done

  cat <<EOS

  Sonraki adımlar
  ───────────────
  1. Tenant claim'i açın (compositions/tenant/examples) — Grafana'da
     "Tenants/<team>-<env>" klasörü + dashboard OTOMATİK belirmeli
     (kabul kriteri #1).
  2. cert-manager expiry alert'i doğrulamak için:
     ./platform/bootstrap/05-observability.sh --only cert-alert-test
  3. OpenCost cost-center raporu:
     kubectl -n opencost port-forward svc/opencost 9003:9003
     curl 'http://localhost:9003/allocation/compute?window=7d&aggregate=label:cost-center'
  4. PLATFORM_CONTEXT.md "Kurulu bileşenler" tablosunu güncelleyin.

  Erişim
  ──────
  Grafana      kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
  Prometheus   kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  Alertmanager kubectl -n observability port-forward svc/alertmanager-operated 9093:9093

EOS
}

# =============================================================================
main() {
  log "Faz 9 — Gözlemlenebilirlik kurulumu"
  [[ "${DRY_RUN}"     == "true" ]] && warn "DRY-RUN: hiçbir değişiklik uygulanmaz"
  [[ "${VERIFY_ONLY}" == "true" ]] && warn "VERIFY-ONLY: yalnızca doğrulama"
  [[ -n "${ONLY}"               ]] && log  "Yalnızca adım: ${ONLY}"

  preflight

  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    should_run kube-prometheus-stack && verify_kube_prometheus_stack || true
    should_run loki                  && verify_loki                  || true
    should_run tempo                 && verify_tempo                 || true
    should_run opencost              && verify_opencost               || true
    summary
    return 0
  fi

  should_run obc                    && apply_obcs
  should_run secrets                && apply_secrets
  should_run kube-prometheus-stack  && sync_kube_prometheus_stack
  should_run loki                   && install_loki
  should_run tempo                  && install_tempo
  should_run opencost               && sync_opencost
  should_run weekly-report          && apply_weekly_report
  should_run cert-alert-test        && [[ -n "${ONLY}" ]] && verify_cert_expiry_alert

  summary
  ok "Faz 9 tamamlandı."
}

main "$@"
