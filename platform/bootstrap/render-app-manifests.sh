#!/usr/bin/env bash
# =============================================================================
# DÜZELTME (Faz 12i, code review #1 — KRİTİK): platform-root Application'ın
# `directory` source'u ArgoCD'nin RESMİ davranışına göre yalnızca `.yaml`,
# `.yml`, `.json` uzantılı dosyaları yükler (bkz. https://argo-cd.readthedocs.io/
# en/stable/user-guide/directory/ — "loads plain manifest files from .yml,
# .yaml, and .json files"). `platform/control-plane/apps/` ve `platform/
# bootstrap/app-of-apps/underlay/`'daki HER dosya `.yaml.tpl` idi — yani
# root-app SIFIR child Application keşfediyordu, ${VAR} render edilse BİLE
# (`check_git_placeholders_resolved()`'ın ÖNCEKİ hâli yalnızca değişken
# çözümlemesini kontrol ediyordu, dosya UZANTISINI DEĞİL — bu yüzden o
# kontrolü geçmek TEK BAŞINA yeterli DEĞİLDİ).
#
# BU SCRIPT NE YAPAR: `.tpl` dosyaları KANONİK ŞABLON (zengin Türkçe
# yorumlarla, fork'lar arası TEKRAR KULLANILABİLİR) olarak KALIR — bu
# script onları SİLMEZ/YENİDEN ADLANDIRMAZ. Bunun yerine, ${VAR}'ları GERÇEK
# değerlerle (versions.env + PLATFORM_REPO_URL/PLATFORM_REPO_REVISION)
# doldurup AYNI ADDA ama `.tpl` UZANTISI OLMADAN bir KARDEŞ dosya üretir
# (`01-cnpg.yaml.tpl` → `01-cnpg.yaml`) — ArgoCD'nin GERÇEKTEN okuduğu
# budur. İKİ dosya da git'e commit edilir (composition'ların function.k/
# composition.yaml İKİLİSİYLE AYNI desen) — `verify-sync.sh` drift'i yakalar.
#
# TENANT_REQUESTS_REPO_URL'e bağımlı 2 dosya (05/06-tenant-requests-*)
# BİLİNÇLİ OLARAK render EDİLMEZ — bu değer henüz YOK (ayrı repo henüz
# oluşturulmadı, bkz. README.md "tenant-requests/ burada iskelet"). O repo
# oluşturulup TENANT_REQUESTS_REPO_URL bilinir hâle gelince bu script
# yeniden çalıştırılmalı.
#
# KULLANIM
#   export PLATFORM_REPO_URL="https://github.com/<org>/<repo>.git"
#   export PLATFORM_REPO_REVISION="main"
#   ./platform/bootstrap/render-app-manifests.sh
#   ./platform/bootstrap/render-app-manifests.sh --verify   # yalnızca drift kontrolü, YAZMAZ
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/platform/underlay/versions.env"
ENV_FILE="${REPO_ROOT}/platform/underlay/.env"

VERIFY_ONLY="false"
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY="true"

[[ -f "${VERSIONS_FILE}" ]] || { echo "HATA: ${VERSIONS_FILE} yok." >&2; exit 1; }
set -a; source "${VERSIONS_FILE}"; set +a

# ÇAĞIRANIN export ettiği PLATFORM_REPO_URL/PLATFORM_REPO_REVISION,
# aşağıdaki .env source'unun ÜZERİNE YAZILMAMALI (.env'de bu ikisi
# genellikle BOŞ bırakılır, bkz. .env.example) — önce yakala, .env'i
# kaynakla, sonra çağıranınkini GERİ YÜKLE (boş değilse).
_caller_repo_url="${PLATFORM_REPO_URL:-}"
_caller_repo_rev="${PLATFORM_REPO_REVISION:-}"
# .env İSTEĞE BAĞLI kaynaklanır — HARBOR_HOSTNAME (policies/security'nin
# ihtiyacı) buradan gelir. Yoksa o dosya sessizce ATLANIR (aşağıdaki
# "çözülmemiş değişken" güvenlik ağı), script BAŞARISIZ OLMAZ.
[[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}"; set +a; }
[[ -n "${_caller_repo_url}" ]] && PLATFORM_REPO_URL="${_caller_repo_url}"
[[ -n "${_caller_repo_rev}" ]] && PLATFORM_REPO_REVISION="${_caller_repo_rev}"

: "${PLATFORM_REPO_URL:?PLATFORM_REPO_URL export edilmeli, bkz. bu dosyanin basligindaki KULLANIM notu}"
: "${PLATFORM_REPO_REVISION:=main}"

# İçinde en az bir ${VAR} referansı geçen HER değişken adı — envsubst'e
# TÜM ortam değişkenlerini vermek yerine yalnızca BİLİNENLERİ listelemek,
# render sonrası "beklenmedik değişken KALDI mı" kontrolünü ANLAMLI kılar.
SUBST_VARS='$PLATFORM_REPO_URL $PLATFORM_REPO_REVISION $HARBOR_HOSTNAME'
while IFS='=' read -r key _; do
  [[ "$key" =~ ^[A-Z_]+$ ]] || continue
  SUBST_VARS="${SUBST_VARS} \$${key}"
done < "${VERSIONS_FILE}"

FAIL="false"

render_dir() {
  local dir="$1"
  local f base out tmp
  for f in "${dir}"/*.yaml.tpl; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .yaml.tpl)"
    out="${dir}/${base}.yaml"

    tmp="$(mktemp)"
    envsubst "${SUBST_VARS}" < "$f" > "$tmp"

    # DÜZELTME'nin KENDİSİNİN sessizce bozuk bir manifest ÜRETMEMESİ için:
    # render SONRASI hâlâ bir ${DEĞIŞKEN_ADI} (yorum İÇİNDE OLMAYAN) kalmışsa
    # bu dosyayı ATLA, uyar — TENANT_REQUESTS_REPO_URL gibi bilinçli olarak
    # çözülmeyen değişkenler İÇİN TASARLANDI (05/06 dosyaları).
    if grep -qE '^\s*[^#[:space:]].*\$\{[A-Z_]+\}' "$tmp"; then
      echo "  ATLANDI (çözülmemiş değişken kaldı): ${f}" >&2
      grep -nE '^\s*[^#[:space:]].*\$\{[A-Z_]+\}' "$tmp" | sed 's/^/    /' >&2
      rm -f "$tmp"
      continue
    fi

    if [[ "${VERIFY_ONLY}" == "true" ]]; then
      if [[ ! -f "$out" ]] || ! diff -q "$tmp" "$out" >/dev/null 2>&1; then
        echo "  DRIFT: ${out} (${f}'den yeniden render edilmemiş)" >&2
        FAIL="true"
      fi
      rm -f "$tmp"
    else
      mv "$tmp" "$out"
      echo "  render edildi: ${out}"
    fi
  done
}

echo "Render ediliyor: platform/control-plane/apps/"
render_dir "${REPO_ROOT}/platform/control-plane/apps"

echo "Render ediliyor: platform/bootstrap/app-of-apps/underlay/"
render_dir "${REPO_ROOT}/platform/bootstrap/app-of-apps/underlay"

echo "Render ediliyor: platform/policies/security/"
render_dir "${REPO_ROOT}/platform/policies/security"

if [[ "${VERIFY_ONLY}" == "true" ]]; then
  if [[ "${FAIL}" == "true" ]]; then
    echo "❌ DRIFT bulundu — yukarıdaki dosyalar için bu script'i --verify OLMADAN çalıştırıp commit edin." >&2
    exit 1
  fi
  echo "✅ Tüm .yaml.tpl → .yaml render'ları SENKRON"
else
  echo "✅ Render tamamlandı. ${REPO_ROOT}'ta 'git status' ile yeni/değişen .yaml dosyalarını inceleyip commit edin."
fi
