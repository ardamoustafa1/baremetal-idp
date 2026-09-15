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
  step "0/5  Ön kontroller"
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
  step "1/5  ObjectBucketClaim + velero-credentials Secret'ı"

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
  step "2/5  Velero ${VELERO_CHART_VERSION} (K8s obje/PV yedekleme)"

  helm_repo vmware-tanzu "${VELERO_HELM_REPO}"
  helm repo update vmware-tanzu >/dev/null

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install velero vmware-tanzu/velero --version ${VELERO_CHART_VERSION}"
    return 0
  fi

  # A repository password must be recoverable independently of this cluster.
  # Never rotate an existing password: that would make old Kopia backups unreadable.
  local repository_secret
  repository_secret="$(kubectl -n velero get secret velero-repo-credentials --ignore-not-found -o name)"
  if [[ -z "${repository_secret}" ]]; then
    [[ -n "${VELERO_REPOSITORY_PASSWORD_FILE:-}" && -s "${VELERO_REPOSITORY_PASSWORD_FILE}" ]] \
      || die "İlk dosya yedeğinden önce VELERO_REPOSITORY_PASSWORD_FILE belirtin; dosyayı küme dışında güvenli saklayın."
    kubectl -n velero create secret generic velero-repo-credentials \
      --from-file="repository-password=${VELERO_REPOSITORY_PASSWORD_FILE}" >/dev/null
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

  wait_for "Velero node-agent" 300 10 \
    kubectl -n velero rollout status daemonset/node-agent --timeout=5s
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
#
# BİLİNÇLİ SINIR (Faz 12m, code review #9'un doğru tespit ettiği): bu test
# YALNIZCA `velero` namespace'inin KENDİ K8s objelerini yedekler VE HİÇBİR
# RESTORE denemesi YAPMAZ — PostgreSQL verisinin (Barman/offsite-sync) veya
# offsite kurtarma yolunun ÇALIŞTIĞINI KANITLAMAZ. GERÇEK bir restore
# tatbikatı (kaynak Ceph erişilemezken offsite'tan geri dönme dahil)
# docs/runbooks/disaster-recovery.md'nin kapsamındadır ve bu script'in
# YERİNE GEÇMEZ.
# =============================================================================
run_backup_smoke_test() {
  step "3/5  Uçtan uca test: on-demand backup"

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

  # DÜZELTME (Faz 12m, code review #9 — YÜKSEK): `grep -q Completed`, TAM
  # eşitlik kontrolü DEĞİLDİR — `PartiallyFailed` gibi bir durum da
  # (kısmi başarısızlık, Velero'nun GERÇEK, belgelenmiş bir terminal
  # fazı) bu regex'i EŞLEŞTİRMEZ (doğru), ama `PartiallyCompleted` gibi
  # VARSAYIMSAL bir gelecekteki faz adı YANLIŞLIKLA "başarılı" sayılırdı —
  # ayrıca `PartiallyFailed` GİBİ bir TERMİNAL başarısızlık durumunda
  # döngü GERÇEK hatayı hemen RAPORLAMAK yerine 180 saniye BOŞ YERE
  # beklemeye devam ederdi. Artık: (a) faza TAM EŞİTLİKLE bakılır, (b)
  # bilinen bir TERMİNAL başarısızlık fazı görülürse döngü HEMEN durur,
  # (c) `status.errors`/`status.warnings` SAYAÇLARI da kontrol edilir
  # (phase="Completed" olsa BİLE errors>0 olabilir — Velero bunu "kısmi"
  # bir başarı olarak işaretleyebilir).
  local _backup_deadline=$(( $(date +%s) + 180 )) _phase _errors
  while true; do
    _phase="$(kubectl -n velero get backup "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${_phase}" in
      Completed) break ;;
      Failed|PartiallyFailed|FailedValidation)
        echo "HATA: Backup '${name}' terminal başarısızlık fazına ulaştı: ${_phase}" >&2
        kubectl -n velero describe backup "${name}" >&2 || true
        exit 1
        ;;
    esac
    (( $(date +%s) < _backup_deadline )) || {
      echo "HATA: Backup '${name}' 180s içinde Completed olmadı (son faz: ${_phase:-boş})" >&2
      kubectl -n velero describe backup "${name}" >&2 || true
      exit 1
    }
    sleep 5
  done
  _errors="$(kubectl -n velero get backup "${name}" -o jsonpath='{.status.errors}' 2>/dev/null || echo 0)"
  [[ -z "${_errors}" || "${_errors}" == "0" ]] \
    || { echo "HATA: Backup '${name}' phase=Completed ama status.errors=${_errors} (kısmi başarısızlık)" >&2; exit 1; }

  log "\$ kubectl -n velero describe backup ${name}"
  kubectl -n velero describe backup "${name}" | sed 's/^/         /'
  ok "On-demand backup GERÇEKTEN tamamlandı (phase=Completed, errors=0) — Velero → Ceph RGW yolu çalışıyor"

  kubectl -n velero delete backup "${name}" --wait=false >/dev/null 2>&1 || true
}

# =============================================================================
# 4. PostgreSQL Barman yedeklerinin (base backup + WAL) küme-dışına
#    SENKRONİZASYONU — Faz 12j, code review #9'un çözümü.
#
# GERÇEK RİSK: Velero'nun offsite BackupStorageLocation'ı yalnızca K8s
# OBJELERİNİ (values-offsite.yaml.tpl'de `deployNodeAgent: false` +
# `volumeSnapshotLocation: []` — bkz. o dosyanın "CSI volume snapshot
# entegrasyonu KAPSAM DIŞI" notu) kapsıyor. PostgreSQL'in GERÇEK verisi
# (`compositions/postgresql/function.k`'nin `backup.barmanObjectStore`'u)
# BİRİNCİL Ceph RGW'ye yazılıyor — offsite hedefte bu verinin BAĞIMSIZ bir
# kopyası YOKTU. Ceph tamamen kaybedilirse, offsite'taki Kubernetes obje
# manifestleriyle veritabanı İÇERİĞİ GERİ GETİRİLEMEZ.
#
# ÇÖZÜM: her tenant Postgres instance'ının backup bucket'ı (`<tenantRef>-
# <name>-backup`, KENDİ namespace'inde bir OBC — rook-ceph'te DEĞİL,
# Loki/Tempo/Velero'nun aksine) için AYRI, TEK-AMAÇLI bir CronJob kurulur.
# Her CronJob YALNIZCA KENDİ bucket'ının ZATEN VAR OLAN, dar kapsamlı OBC
# kimlik bilgilerini kullanır — YENİ bir Ceph RGW admin/cross-bucket
# kimliği İCAT EDİLMEDİ (böyle bir şeyin doğru radosgw-admin semantiği bu
# ortamda DOĞRULANAMAZDI; bunun yerine ZATEN kanıtlanmış, OBC-başına
# izolasyon deseni yeniden kullanıldı). `amazon/aws-cli` imajı, iki S3
# uç noktası arasında (Ceph RGW ↔ offsite) iki adımlı bir sync yapar
# (indir → yükle — S3 API'si bucket'lar arası DOĞRUDAN kopyalamayı,
# farklı sağlayıcılar arasında, desteklemez).
#
# BİLİNÇLİ SINIR: keşif bu script'in çalıştığı ANDA VAR OLAN bucket'ları
# bulur — YENİ bir tenant Postgres instance'ı SONRADAN oluşturulursa, o
# bucket'ın offsite sync CronJob'unu almak için bu adım (`--only
# postgres-offsite-sync`) TEKRAR çalıştırılmalıdır (TLS yenilemesiyle AYNI
# "operatör periyodik olarak tetikler" deseni — bkz. pki/vault/README.md
# "Sertifika yenileme").
# =============================================================================
setup_postgres_offsite_sync() {
  step "4/5  PostgreSQL Barman yedeklerinin küme-dışına senkronizasyonu"

  if [[ "${VELERO_OFFSITE_ENABLED}" != "true" ]]; then
    log "  VELERO_OFFSITE_ENABLED=false — bu adım atlanıyor (K8s objelerinin"
    log "  offsite kopyası da yok; bkz. Özet'teki uyarı)."
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] postgres-*-backup OBC'leri keşfedilip offsite sync CronJob'ları render edilecekti"
    return 0
  fi

  kubectl create namespace offsite-sync --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label namespace offsite-sync platform.internal/layer=control-plane --overwrite >/dev/null

  # DÜZELTME: Postgres backup OBC'leri `rook-ceph` namespace'inde DEĞİL —
  # `compositions/postgresql/function.k`'nin `backupBucket`si KENDİ tenant
  # namespace'inde yaşar (bkz. o dosyanın `metadata.namespace = tenantRef`).
  # Tüm namespace'lerde `platform.internal/component=postgresql` etiketli
  # OBC'ler aranır.
  local obcs synced=0
  obcs="$(kubectl get objectbucketclaim --all-namespaces \
    -l platform.internal/component=postgresql \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.bucketName}{"\n"}{end}' 2>/dev/null || true)"

  if [[ -z "${obcs}" ]]; then
    warn "  Hiçbir postgres-*-backup OBC'si bulunamadı — henüz Postgres instance'ı yok olabilir. Bu adım daha sonra tekrar çalıştırılabilir."
    return 0
  fi

  while IFS=' ' read -r ns obc_name bucket_name; do
    [[ -z "${ns}" ]] && continue
    local key secret
    key="$(kubectl -n "${ns}" get secret "${obc_name}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)"
    secret="$(kubectl -n "${ns}" get secret "${obc_name}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)"
    if [[ -z "${key}" || -z "${secret}" ]]; then
      warn "  ${ns}/${obc_name}: kimlik bilgisi okunamadı, atlanıyor"
      continue
    fi

    # DÜZELTME (Faz 12m, code review #8 — YÜKSEK): `job_name` ÖNCEDEN
    # yalnızca ilk 52 karaktere KESİLİYORDU — iki FARKLI uzun bucket adı
    # (ör. iki farklı tenant'ın uzun teamName'leri) AYNI ilk 52 karaktere
    # sahipse, İKİNCİ CronJob/Secret BİRİNCİYİ SESSİZCE ÜZERİNE YAZARDI
    # (`kubectl apply` idempotent'tir — "zaten var" hatası VERMEZ, aynı
    # ada SAHİP farklı bir kaynağı GÜNCELLER) — bir tenant'ın yedek
    # kimlik bilgisi/hedefi BAŞKA bir tenant'ınkiyle DEĞİŞTİRİLİR, o
    # tenant'ın yedeği SESSİZCE senkronize edilmeyi BIRAKIR. ÇÖZÜM: TAM
    # bucket_name'in SHA-256'sının ilk 8 hex karakteri, kesilmiş adın
    # SONUNA eklenir — iki FARKLI bucket adının AYNI (kesilmiş taban +
    # hash) çifti üretmesi için ÖNCE ilk ~43 karakterde ÇAKIŞMALARI HEM
    # DE SHA-256'da çakışması gerekir (pratikte imkansız).
    local bucket_hash; bucket_hash="$(printf '%s' "${bucket_name}" | sha256sum | cut -c1-8)"
    local job_name="offsite-sync-${bucket_name}"
    job_name="${job_name:0:43}-${bucket_hash}"

    kubectl -n offsite-sync create secret generic "${job_name}-creds" \
      --from-literal="SRC_ACCESS_KEY=${key}" \
      --from-literal="SRC_SECRET_KEY=${secret}" \
      --from-literal="DST_ACCESS_KEY=${VELERO_OFFSITE_S3_ACCESS_KEY}" \
      --from-literal="DST_SECRET_KEY=${VELERO_OFFSITE_S3_SECRET_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    JOB_NAME="${job_name}" BUCKET_NAME="${bucket_name}" \
      envsubst '${JOB_NAME} ${BUCKET_NAME} ${CEPH_OBJECTSTORE_NAME} ${VELERO_OFFSITE_S3_URL} ${VELERO_OFFSITE_S3_REGION} ${OFFSITE_SYNC_RCLONE_IMAGE}' \
      < "${VELERO_DIR}/templates/offsite-sync-cronjob.yaml.tpl" \
      | kubectl apply -f -

    ok "  offsite sync CronJob: ${job_name} (bucket: ${bucket_name}, kaynak ns: ${ns})"
    synced=$(( synced + 1 ))
  done <<< "${obcs}"

  ok "PostgreSQL offsite sync: ${synced} bucket için CronJob kuruldu (günlük 04:00 UTC — Velero'nun K8s obje senkronundan 1 saat SONRA)"
}

# =============================================================================
# 5. offsite-sync-discovery CronJob'u — Faz 12m, code review #6'nın çözümü.
#
# GERÇEK RİSK: `setup_postgres_offsite_sync()` (yukarıda) yalnızca
# ÇALIŞTIĞI ANDA VAR OLAN postgres backup bucket'larını keşfeder — SONRADAN
# oluşturulan bir tenant/Postgres instance'ı için bu adımın (`06-velero.sh
# --only postgres-offsite-sync`) İNSAN tarafından ELLE tekrar çalıştırılması
# GEREKİRDİ. Unutulursa, self-servis olarak "hazır" görünen bir prod
# veritabanının BAĞIMSIZ (offsite) yedeği HİÇ OLMAZ — sessizce.
#
# ÇÖZÜM: yukarıdaki KEŞİF+CronJob-ÜRETME mantığının AYNISINI (bash yerine
# POSIX sh ile, kubectl + temel coreutils kullanarak) HER SAAT çalıştıran
# bir CronJob küme İÇİNE kuruluyor — insan hafızasına bağımlı MANUEL bir
# adım, kendi kendini periyodik olarak TEKRARLAYAN bir mekanizmaya dönüşüyor.
#
# DÜZELTME (code review #6, YÜKSEK — güvenlik kapsamı): bu CronJob'un
# ServiceAccount'ı ÖNCEDEN `secrets` kaynağını KÜME GENELİNDE `get`
# edebiliyordu — bu ServiceAccount/pod ele geçirilirse YALNIZCA postgres
# backup Secret'ları DEĞİL, ADI BİLİNEN/TAHMİN EDİLEN HER namespace'teki
# HER Secret (örn. `vault-server-tls`, `backstage-oidc-client-secret`)
# okunabilirdi. ÇÖZÜM: küme geneli `secrets: get` TAMAMEN KALDIRILDI —
# `compositions/postgresql/function.k`'ye YENİ bir composed kaynak
# (`offsiteDiscoveryRole`/`offsiteDiscoveryRoleBinding`) eklendi: HER
# Postgres instance'ı KENDİ namespace'inde, offsite-sync-discovery
# ServiceAccount'ına `resourceNames: ["<name>-backup"]` ile SINIRLI (TAM
# OLARAK o instance'ın backup Secret'ı, BAŞKA HİÇBİR Secret DEĞİL) bir
# Role/RoleBinding oluşturur. Composition zaten KENDİ ürettiği namespace'te
# yetkiliDİR (Crossplane'in KENDİ yönettiği kaynak) — bu, K8s RBAC'ın
# statik doğasıyla mümkün olan EN DAR kapsam (içerik-bazlı, "yalnızca
# postgres backup'ları" gibi bir kısıt RBAC'ta İFADE EDİLEMEZ, ama
# "yalnızca BU tek, isimle sabitlenmiş Secret" İFADE EDİLEBİLİR ve
# EDİLDİ). YAZMA yetkisi HÂLÂ yalnızca `offsite-sync` namespace'iyle
# SINIRLI (cluster-wide DEĞİL, değişmedi).
# =============================================================================
setup_offsite_sync_discovery_cronjob() {
  step "5/5  offsite-sync-discovery CronJob'u (saatlik otomatik keşif)"

  if [[ "${VELERO_OFFSITE_ENABLED}" != "true" ]]; then
    log "  VELERO_OFFSITE_ENABLED=false — bu adım atlanıyor."
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] offsite-sync-discovery RBAC + ConfigMap + CronJob uygulanacaktı"
    return 0
  fi

  kubectl create namespace offsite-sync --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # --- RBAC: OBC keşfi küme-geneli (içerik SIR DEĞİL — yalnızca bucket
  # adı/namespace listelenir), yazma yalnızca offsite-sync namespace'i ile
  # SINIRLI. `secrets: get` KÜME GENELİNDEN KALDIRILDI (code review #6) —
  # her tenant'ın KENDİ backup Secret'ına erişim artık `compositions/
  # postgresql/function.k`'nin ürettiği namespace-özel Role/RoleBinding
  # ile veriliyor (bkz. yukarıdaki DÜZELTME notu).
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: offsite-sync-discovery
  namespace: offsite-sync
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: offsite-sync-discovery
rules:
  - apiGroups: ["objectbucket.io"]
    resources: ["objectbucketclaims"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: offsite-sync-discovery
subjects:
  - kind: ServiceAccount
    name: offsite-sync-discovery
    namespace: offsite-sync
roleRef:
  kind: ClusterRole
  name: offsite-sync-discovery
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: offsite-sync-discovery
  namespace: offsite-sync
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: ["batch"]
    resources: ["cronjobs"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: offsite-sync-discovery
  namespace: offsite-sync
subjects:
  - kind: ServiceAccount
    name: offsite-sync-discovery
    namespace: offsite-sync
roleRef:
  kind: Role
  name: offsite-sync-discovery
  apiGroup: rbac.authorization.k8s.io
EOF

  # --- Discovery CronJob'unun KENDİ uygulayacağı per-bucket şablonu — AYNI
  # `offsite-sync-cronjob.yaml.tpl`, ama `JOB_NAME`/`BUCKET_NAME` BİLİNÇLİ
  # OLARAK ÇÖZÜLMEDEN bırakılıyor (discovery script'i bunları HER bucket
  # için KENDİSİ `sed` ile dolduracak).
  local work; work="$(mktemp -d)"
  envsubst '${CEPH_OBJECTSTORE_NAME} ${VELERO_OFFSITE_S3_URL} ${VELERO_OFFSITE_S3_REGION} ${OFFSITE_SYNC_RCLONE_IMAGE}' \
    < "${VELERO_DIR}/templates/offsite-sync-cronjob.yaml.tpl" \
    > "${work}/cronjob-template.yaml"

  cat > "${work}/discover.sh" <<'DISCOVER_EOF'
#!/bin/sh
set -eu
# DÜZELTME (code review #7, YÜKSEK): bu script ÖNCEDEN `kubectl get ... ||
# true` ile OBC listeleme HATASINI YUTUYORDU — API/RBAC sorunu YÜZÜNDEN
# kubectl BAŞARISIZ olduğunda `/tmp/obcs.txt` BOŞ kalır, script bunu
# "hiçbir postgres backup OBC'si YOK" (exit 0, BAŞARILI) ile AYNI şekilde
# yorumlardı — yani bir API/RBAC arızası, discovery'nin BAŞARIYLA
# ÇALIŞTIĞI ama basitçe "yedeklenecek veritabanı yok" sanılan bir duruma
# tamamen ÖZDEŞ görünürdü. Artık kubectl'in KENDİ exit kodu AYRI YAKALANIR
# — "gerçekten sıfır kaynak var" (kubectl BAŞARILI, çıktı boş) ile
# "kaynakları OKUYAMADIM" (kubectl BAŞARISIZ) İKİ FARKLI, birbirinden
# AYRIŞTIRILABİLİR sonuçtur.
echo "[discovery] postgres backup OBC'leri taranıyor..."
if ! kubectl get objectbucketclaim --all-namespaces \
  -l platform.internal/component=postgresql \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.bucketName}{"\n"}{end}' \
  > /tmp/obcs.txt; then
  echo "[discovery] HATA: OBC listelemesi BAŞARISIZ (kubectl exit != 0) — bu API/RBAC arızası OLABİLİR, 'hiçbir OBC yok' İLE KARIŞTIRILMAMALI. Job BAŞARISIZ SAYILIYOR." >&2
  exit 1
fi

if [ ! -s /tmp/obcs.txt ]; then
  echo "[discovery] kubectl BAŞARIYLA çalıştı ve GERÇEKTEN sıfır postgres backup OBC'si döndürdü (yeni kurulum/henüz hiç tenant yok VARSAYIMI)."
  exit 0
fi

# DÜZELTME (code review #7): bir Secret okunamadığında yalnızca o veritabanı
# ATLANIP script SESSİZCE "başarılı" (exit 0) çıkardı — bir RBAC/erişim
# regresyonu (örn. #6'nın YENİ namespace-özel Role'ü BEKLENMEDİK şekilde
# eksikse) discovery'yi "çalışıyor ama yeni veritabanları eklenmiyor" gibi
# SESSİZCE bozardı. Artık atlanan HER veritabanı SAYILIR; en az bir atlama
# varsa script SONUNDA BAŞARISIZ SAYILIR (aşağıya bakın) — CronJob'un
# `failedJobsHistoryLimit`i ve gelecekteki bir alerting entegrasyonu bunu
# GÖRÜNÜR kılar.
skipped_count=0
while read -r ns obc_name bucket_name; do
  [ -z "${ns:-}" ] && continue
  key="$(kubectl -n "${ns}" get secret "${obc_name}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)"
  secret="$(kubectl -n "${ns}" get secret "${obc_name}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)"
  if [ -z "${key}" ] || [ -z "${secret}" ]; then
    echo "[discovery] UYARI: ${ns}/${obc_name}: kimlik bilgisi OKUNAMADI (RBAC/eksik Secret olabilir), ATLANIYOR — bu veritabanı offsite koruması ALMAYACAK." >&2
    skipped_count=$((skipped_count + 1))
    continue
  fi

  bucket_hash="$(printf '%s' "${bucket_name}" | sha256sum | cut -c1-8)"
  base_name="offsite-sync-${bucket_name}"
  job_name="$(printf '%s' "${base_name}" | cut -c1-43)-${bucket_hash}"

  kubectl -n offsite-sync create secret generic "${job_name}-creds" \
    --from-literal="SRC_ACCESS_KEY=${key}" \
    --from-literal="SRC_SECRET_KEY=${secret}" \
    --from-literal="DST_ACCESS_KEY=${DST_ACCESS_KEY}" \
    --from-literal="DST_SECRET_KEY=${DST_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  sed -e "s|\${JOB_NAME}|${job_name}|g" -e "s|\${BUCKET_NAME}|${bucket_name}|g" \
    /etc/offsite-sync/cronjob-template.yaml | kubectl apply -f -

  echo "[discovery] offsite sync CronJob: ${job_name} (bucket: ${bucket_name}, kaynak ns: ${ns})"
done < /tmp/obcs.txt

if [ "${skipped_count}" -gt 0 ]; then
  echo "[discovery] HATA: ${skipped_count} veritabanının kimlik bilgisi okunamadı — bu veritabanları offsite koruması ALMADI. Job BAŞARISIZ SAYILIYOR (bkz. yukarıdaki UYARI satırları)." >&2
  exit 1
fi
echo "[discovery] tamamlandı — atlanan veritabanı yok."
DISCOVER_EOF

  kubectl -n offsite-sync create configmap offsite-sync-discovery \
    --from-file="cronjob-template.yaml=${work}/cronjob-template.yaml" \
    --from-file="discover.sh=${work}/discover.sh" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n offsite-sync create secret generic offsite-sync-discovery-dst-creds \
    --from-literal="DST_ACCESS_KEY=${VELERO_OFFSITE_S3_ACCESS_KEY}" \
    --from-literal="DST_SECRET_KEY=${VELERO_OFFSITE_S3_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  rm -rf "${work}"

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: CronJob
metadata:
  name: offsite-sync-discovery
  namespace: offsite-sync
  labels:
    platform.internal/managed-by: velero-bootstrap
spec:
  schedule: "0 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      activeDeadlineSeconds: 600
      template:
        spec:
          serviceAccountName: offsite-sync-discovery
          restartPolicy: OnFailure
          containers:
            - name: discover
              image: ${OFFSITE_SYNC_DISCOVERY_IMAGE}
              command: ["/bin/sh", "/etc/offsite-sync/discover.sh"]
              envFrom:
                - secretRef: {name: offsite-sync-discovery-dst-creds}
              resources:
                requests: {cpu: 50m, memory: 64Mi}
                limits: {cpu: 200m, memory: 128Mi}
              volumeMounts:
                - {name: script, mountPath: /etc/offsite-sync}
          volumes:
            - name: script
              configMap:
                name: offsite-sync-discovery
                defaultMode: 0555
EOF

  ok "offsite-sync-discovery CronJob'u kuruldu (saatlik, 0 * * * *) — YENİ Postgres instance'ları artık ELLE re-run GEREKTİRMEZ"
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

  should_run obc                    && apply_obc_and_secret
  should_run velero                 && install_velero
  should_run schedule-test          && run_backup_smoke_test
  should_run postgres-offsite-sync  && setup_postgres_offsite_sync
  should_run offsite-sync-discovery && setup_offsite_sync_discovery_cronjob

  summary
  ok "Velero kurulumu tamamlandı."
}

main "$@"
