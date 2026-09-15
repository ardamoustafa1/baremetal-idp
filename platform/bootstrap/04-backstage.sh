#!/usr/bin/env bash
# =============================================================================
# Faz 8 — Backstage Developer Portal
#
#   RBAC + SecretStore/ExternalSecret'ler → Keycloak client secret'ını
#   Vault'a yaz (TEK SEFERLİK, admin token ile) → Backstage Helm kurulumu
#   → app-config.yaml'ı ConfigMap olarak uygula → scaffolder template'leri
#   + catalog entity'lerini uygula
#
# Uygulama kaynakları platform/backstage/portal altında; Dockerfile ile build edilir.
# KULLANIM
#   export VAULT_TOKEN="<docs/runbooks/vault-unseal.md §3.3'ten>"
#   ./platform/bootstrap/04-backstage.sh
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
UNDERLAY_DIR="${REPO_ROOT}/platform/underlay"
BACKSTAGE_DIR="${REPO_ROOT}/platform/backstage"
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
log()  { printf '%s [%s] %s\n'   "$(_ts)" "${C_BLU}INFO${C_RST}" "$*"; }
ok()   { printf '%s [%s]   %s\n' "$(_ts)" "${C_GRN} OK ${C_RST}" "$*"; }
warn() { printf '%s [%s] %s\n'   "$(_ts)" "${C_YLW}WARN${C_RST}" "$*" >&2; }
err()  { printf '%s [%s] %s\n'   "$(_ts)" "${C_RED}FAIL${C_RST}" "$*" >&2; }
step() { printf '\n%s%s══ %s %s%s\n' "${C_BLD}" "${C_BLU}" "$*" "══" "${C_RST}"; }
die()  { err "$*"; exit 1; }
trap 'err "Satır ${LINENO}: komut başarısız (exit=$?)."' ERR

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)        ONLY="${2:-}"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --verify-only) VERIFY_ONLY="true"; shift ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)             die "Bilinmeyen argüman: $1" ;;
  esac
done
should_run() { [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]; }

VAULT_TLS_ENABLED="false"

preflight() {
  step "0/4  Ön kontroller"
  for bin in kubectl helm jq curl openssl python3; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' bulunamadı."
  done
  kubectl cluster-info >/dev/null 2>&1 || die "Cluster'a ulaşılamıyor."
  set -a; source "${VERSIONS_FILE}"; set +a
  set -a; source "${ENV_FILE}"; set +a
  [[ -n "${VAULT_TOKEN:-}" ]] || die \
"VAULT_TOKEN boş. export VAULT_TOKEN=\"<docs/runbooks/vault-unseal.md §3.3'ten>\"
     (yalnızca bu shell oturumunda kalır, hiçbir dosyaya yazılmaz)"

  # DÜZELTME (bu turda, taze bir denetimde bulundu — KRİTİK): `vexec()`
  # ÖNCEDEN HER ZAMAN sabit `http://127.0.0.1:8200` kullanıyordu — ama Faz 3
  # (03-pki.sh) `enable_vault_tls()` çalıştıktan SONRA Vault'un TEK
  # listener'ı (loopback 127.0.0.1 DAHİL, pod içinde AYRI bir plaintext
  # listener YOK) yalnızca HTTPS dinler. Backstage bootstrap'ı (Faz 8)
  # TASARIM GEREĞİ Faz 3'ten SONRA çalıştığı için `vexec()` HER ZAMAN
  # bağlantı reddiyle başarısız oluyordu — Keycloak'ta 'backstage' client'ı
  # OLUŞTURULUP Vault'a YAZILAMADAN script çöküyor, yarı-yapılandırılmış bir
  # durum bırakıyordu. ÇÖZÜM: `03-pki.sh`'in KENDİ `vexec()`'İYLE BİREBİR
  # AYNI desen — `vault-server-tls` Secret'ının VARLIĞI TLS'in etkin
  # olduğunun sinyali (kubectl/cluster erişimi bu noktada ZATEN doğrulandı).
  if kubectl -n vault get secret vault-server-tls >/dev/null 2>&1; then
    VAULT_TLS_ENABLED="true"
    log "  Vault listener TLS etkin (Secret vault/vault-server-tls mevcut) — vexec() HTTPS kullanacak."
  else
    log "  Vault listener TLS henüz etkin DEĞİL — vexec() HTTP kullanacak."
  fi

  ok "Ön kontroller tamam"
}

vexec() {
  local addr="http://127.0.0.1:8200" skip_verify=""
  if [[ "${VAULT_TLS_ENABLED}" == "true" ]]; then
    addr="https://127.0.0.1:8200"
    skip_verify='VAULT_SKIP_VERIFY=true; export VAULT_SKIP_VERIFY'
  fi
  kubectl -n vault exec vault-0 -- sh -c \
    "VAULT_ADDR=${addr}; export VAULT_ADDR
     ${skip_verify}
     VAULT_TOKEN=\"\$1\"; export VAULT_TOKEN
     shift
     exec vault \"\$@\"" \
    -- "${VAULT_TOKEN}" "$@"
}

# =============================================================================
# 1. Keycloak client secret'ını Vault'a yaz (TEK SEFERLİK)
# =============================================================================
sync_oidc_secret_to_vault() {
  step "1/4  Keycloak 'backstage' client secret'ı → Vault"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] Keycloak admin API'den secret okunup Vault'a yazılacaktı"
    return 0
  fi

  # DÜZELTME (bu turda, taze bir denetimde bulundu — ORTA): admin parolası
  # VE bearer token'lar ÖNCEDEN `curl -d "password=..."` / `-H "Authorization:
  # Bearer ${admin_token}"` ile DOĞRUDAN `kubectl exec` komut ARGV'sine
  # yazılıyordu — bu, `kubectl exec sts/keycloak -- ps aux` VEYA
  # `/proc/<pid>/cmdline` erişimi olan HERKESE (VAULT_TOKEN için script'in
  # ZATEN kaçındığı AYNI sınıf risk) sızıyordu. ÇÖZÜM: hem parola HEM
  # token'lar artık curl'ün `-K -` (config-from-stdin) özelliğiyle,
  # `kubectl exec -i`'nin CALLER'DAN pod'a ilettiği bir heredoc İÇİNDE
  # taşınıyor — argv'de HİÇBİR sır YOK. `/tmp/kc-authrc` (pod içinde,
  # `sts/keycloak` KALICI bir pod olduğu için — Harbor'un `--rm` pod'larının
  # AKSİNE) fonksiyonun HEM BAŞINDA (önceki başarısız bir koşudan kalan
  # dosya varsa) HEM SONUNDA temizlenir.
  local kc_admin_pw client_secret admin_token
  kc_admin_pw="$(kubectl -n keycloak get secret keycloak-admin-password \
                 -o jsonpath='{.data.admin-password}' | base64 -d)"

  kubectl -n keycloak exec sts/keycloak -- rm -f /tmp/kc-authrc 2>/dev/null || true

  admin_token="$(kubectl -n keycloak exec -i sts/keycloak -- curl -sf -K - \
    "http://localhost:8080/realms/master/protocol/openid-connect/token" <<CURLCONF | jq -r '.access_token'
data = "client_id=admin-cli"
data-urlencode = "username=${KEYCLOAK_ADMIN_USER}"
data-urlencode = "password=${kc_admin_pw}"
data = "grant_type=password"
CURLCONF
)"
  [[ -n "${admin_token}" && "${admin_token}" != "null" ]] || die "Keycloak admin token alınamadı"

  # Bearer token'ı pod-içi bir curl config dosyasına YAZ (argv'de DEĞİL) —
  # aşağıdaki 4 kimlik-doğrulamalı çağrının hepsi `-K /tmp/kc-authrc`
  # KULLANIR, token'ı TEKRAR TEKRAR argv'ye koymaz.
  kubectl -n keycloak exec -i sts/keycloak -- sh -c 'umask 077; cat > /tmp/kc-authrc' <<CURLCONF
header = "Authorization: Bearer ${admin_token}"
CURLCONF

  # Realm import existing realm'leri güncellemez: client'ı burada idempotent oluştur/güncelle.
  local client_payload
  client_payload="$(jq -n --arg domain "${PLATFORM_BASE_DOMAIN}" '{
    clientId: "backstage", name: "Backstage Developer Portal", enabled: true,
    publicClient: false, protocol: "openid-connect", standardFlowEnabled: true,
    directAccessGrantsEnabled: false,
    redirectUris: [("https://backstage." + $domain + "/api/auth/oidc/handler/frame")],
    webOrigins: [("https://backstage." + $domain)],
    defaultClientScopes: ["profile", "email", "roles", "groups"]
  }')"
  local client_uuid
  client_uuid="$(kubectl -n keycloak exec sts/keycloak -- curl -sf -K /tmp/kc-authrc \
    "http://localhost:8080/admin/realms/${KEYCLOAK_REALM}/clients?clientId=backstage" \
    | jq -r '.[0].id')"
  if [[ -z "${client_uuid}" || "${client_uuid}" == "null" ]]; then
    kubectl -n keycloak exec sts/keycloak -- curl -sf -X POST -K /tmp/kc-authrc \
      -H 'Content-Type: application/json' \
      --data "${client_payload}" "http://localhost:8080/admin/realms/${KEYCLOAK_REALM}/clients"
    client_uuid="$(kubectl -n keycloak exec sts/keycloak -- curl -sf -K /tmp/kc-authrc \
      "http://localhost:8080/admin/realms/${KEYCLOAK_REALM}/clients?clientId=backstage" | jq -er '.[0].id')"
  else
    kubectl -n keycloak exec sts/keycloak -- curl -sf -X PUT -K /tmp/kc-authrc \
      -H 'Content-Type: application/json' \
      --data "${client_payload}" "http://localhost:8080/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}"
  fi

  client_secret="$(kubectl -n keycloak exec sts/keycloak -- curl -sf -K /tmp/kc-authrc \
    "http://localhost:8080/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/client-secret" \
    | jq -r '.value')"
  kubectl -n keycloak exec sts/keycloak -- rm -f /tmp/kc-authrc 2>/dev/null || true
  [[ -n "${client_secret}" && "${client_secret}" != "null" ]] || die "client secret okunamadı"

  vexec kv put -mount=kv platform/backstage/oidc clientSecret="${client_secret}"
  ok "  Keycloak client secret'ı kv/platform/backstage/oidc'e yazıldı"
  if ! vexec kv get -mount=kv platform/backstage/session >/dev/null 2>&1; then
    vexec kv put -mount=kv platform/backstage/session secret="$(openssl rand -hex 32)"
  fi
  warn "  NOT: GitHub token (kv/platform/backstage/github) ve DB bağlantısı"
  warn "  (kv/platform/backstage/database) BU SCRIPT TARAFINDAN YAZILMAZ —"
  warn "  bkz. backstage/README.md 'İlk kurulum — elle yapılacaklar'"
}

# =============================================================================
# 2. RBAC + SecretStore/ExternalSecret + Backstage Helm kurulumu
# =============================================================================
install_backstage() {
  step "2/4  Backstage (Helm)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] helm upgrade --install backstage --version ${BACKSTAGE_CHART_VERSION}"
    return 0
  fi

  python3 "${BACKSTAGE_DIR}/configure.py"
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "${BACKSTAGE_DIR}/app/resources/"

  helm_repo() {
    helm repo list -o json 2>/dev/null | jq -e --arg n "$1" '.[]|select(.name==$n)' >/dev/null \
      || helm repo add "$1" "$2" >/dev/null
  }
  helm_repo backstage "${BACKSTAGE_HELM_REPO}"
  helm repo update backstage >/dev/null

  # app-config.yaml, Backstage'in KENDİ ${VAR} runtime-interpolation'ını
  # KULLANIR (envsubst DEĞİL) — bkz. app-config.yaml başlığı. OLDUĞU GİBİ
  # bir ConfigMap'e konur.
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n backstage create configmap backstage-app-config \
    --from-file=app-config.yaml="${BACKSTAGE_DIR}/app/app-config.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "  app-config ConfigMap uygulandı"

  helm upgrade --install backstage backstage/backstage \
    --namespace backstage --version "${BACKSTAGE_CHART_VERSION}" \
    -f "${BACKSTAGE_DIR}/app/values.yaml" \
    --wait --timeout 10m

  verify_backstage
}

verify_backstage() {
  log "DOĞRULAMA: Backstage"
  kubectl -n backstage get pods,svc,externalsecret 2>/dev/null | sed 's/^/         /'
  kubectl -n backstage rollout status deployment/backstage --timeout=180s
  kubectl -n backstage wait --for=condition=Ready externalsecret --all --timeout=180s
  ok "Backstage deployment Ready; SSO ayrıca tarayıcıda doğrulanmalı"

}

# =============================================================================
# 3. Scaffolder template'leri + catalog entity'leri (Backstage kendi
#    app-config.yaml'ındaki 'catalog.locations' üzerinden bunları zaten
#    okuyor — bu adım yalnızca dosyaların REPO'da (dolayısıyla Backstage'in
#    okuduğu konumda) var olduğunu doğrular, ayrıca kubectl apply GEREKMEZ.
# =============================================================================
verify_templates_and_catalog() {
  step "3/4  Scaffolder template'leri + catalog entity'leri"
  for f in \
    "${BACKSTAGE_DIR}/templates/create-tenant/template.yaml" \
    "${BACKSTAGE_DIR}/templates/request-postgres/template.yaml" \
    "${BACKSTAGE_DIR}/catalog/organization.yaml" \
    "${BACKSTAGE_DIR}/catalog/platform-components.yaml"; do
    [[ -f "$f" ]] && ok "  bulundu: ${f#"${REPO_ROOT}"/}" || { err "  EKSİK: $f"; return 1; }
  done
}

# =============================================================================
main() {
  log "Faz 8 — Backstage kurulumu"
  preflight

  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    if should_run backstage; then verify_backstage; fi
    if should_run templates; then verify_templates_and_catalog; fi
    return 0
  fi

  if should_run oidc; then sync_oidc_secret_to_vault; fi
  if should_run backstage; then install_backstage; fi
  if should_run templates; then verify_templates_and_catalog; fi

  cat <<EOS

  Sonraki adımlar
  ───────────────
  1. GitHub token'ı Vault'a yazın (bu script YAZMAZ — bkz. README):
     vault kv put -mount=kv platform/backstage/github token="<PAT>"
  2. Backstage DB bağlantısını Vault'a yazın (Faz 4'ün CNPG'si kurulunca):
     vault kv put -mount=kv platform/backstage/database host=... port=... username=... password=...
  3. Gerçek Backstage app image'ını build edip Harbor'a push edin, sonra
     platform/backstage/app/values.yaml'daki image.repository/tag'i güncelleyin.
  4. scaffolder template'lerindeki 'REPLACE_ME' org/repo adlarını değiştirin.

EOS
  ok "Faz 8 (script kısmı) tamamlandı."
}

main "$@"
