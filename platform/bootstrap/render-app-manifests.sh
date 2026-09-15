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
# TENANT_REQUESTS_REPO_URL'e bağımlı 2 dosya (05/06-tenant-requests-*):
# değer BOŞSA render edilmez (ayrı tenant-requests reposu henüz YOK, bkz.
# README.md "tenant-requests/ burada iskelet") — `--require-tenant-requests`
# bayrağı OLMADAN bu, sessiz bir "ATLANDI" uyarısıyla geçilir (bootstrap'ın
# erken aşaması için GEÇERLİ); bayrakla ÇALIŞTIRILIRSA aynı durum artık
# SERT bir HATADIR (canlıya geçiş kontrol listesi). Değer DOLUYSA (repo
# kurulup TENANT_REQUESTS_REPO_URL export edildiyse) bayraktan BAĞIMSIZ
# olarak HER ZAMAN normal şekilde render edilir. Bkz. aşağıdaki KULLANIM
# ve code review #11'in çözümü — DAHA ÖNCE TENANT_REQUESTS_REPO_URL
# SUBST_VARS listesinde HİÇ yoktu (export edilse bile envsubst onu asla
# çözemezdi) VE atlama her koşulda sessizce "SENKRON" başarısına karışıyordu.
#
# KULLANIM
#   export PLATFORM_REPO_URL="https://github.com/<org>/<repo>.git"
#   export PLATFORM_REPO_REVISION="main"
#   ./platform/bootstrap/render-app-manifests.sh
#   ./platform/bootstrap/render-app-manifests.sh --verify   # yalnızca drift kontrolü, YAZMAZ
#
#   # tenant-requests reposu OLUŞTUKTAN SONRA (bkz. aşağıdaki DÜZELTME,
#   # code review #11):
#   export TENANT_REQUESTS_REPO_URL="https://github.com/<org>/tenant-requests.git"
#   ./platform/bootstrap/render-app-manifests.sh --require-tenant-requests
#   ./platform/bootstrap/render-app-manifests.sh --verify --require-tenant-requests
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
VERSIONS_FILE="${REPO_ROOT}/platform/underlay/versions.env"
ENV_FILE="${REPO_ROOT}/platform/underlay/.env"

VERIFY_ONLY="false"
# DÜZELTME (code review #11): `TENANT_REQUESTS_REPO_URL` boşken 05/06
# dosyalarının "ATLANDI" olarak sessizce geçilmesi ÖNCEDEN her koşulda
# kabul ediliyordu — bootstrap'ın ERKEN aşamasında (tenant-requests reposu
# henüz YOKKEN) doğru, ama tenant-requests reposu KURULDUKTAN SONRA bu
# atlama artık bir HATADIR (self-servis GitOps akışı GERÇEKTE devrede
# değilken `--verify` yine de "SENKRON" raporlar). `--require-tenant-requests`
# bu iki dosyanın skip'ini HATAYA çevirir (VE TENANT_REQUESTS_REPO_URL
# boşsa script'i erkenden durdurur — aşağıya bakın) — CI'da varsayılan
# (bayraksız) çalıştırma bootstrap-öncesi aşamayı, bu bayrak GERÇEK
# canlıya geçiş kontrol listesini temsil eder.
REQUIRE_TENANT_REQUESTS="false"
for _arg in "$@"; do
  case "${_arg}" in
    --verify)                    VERIFY_ONLY="true" ;;
    --require-tenant-requests)   REQUIRE_TENANT_REQUESTS="true" ;;
  esac
done

if [[ "${REQUIRE_TENANT_REQUESTS}" == "true" ]] && [[ -z "${TENANT_REQUESTS_REPO_URL:-}" ]]; then
  echo "HATA: --require-tenant-requests verildi ama TENANT_REQUESTS_REPO_URL boş/export edilmemiş." >&2
  exit 1
fi

[[ -f "${VERSIONS_FILE}" ]] || { echo "HATA: ${VERSIONS_FILE} yok." >&2; exit 1; }
set -a; source "${VERSIONS_FILE}"; set +a

# ÇAĞIRANIN export ettiği PLATFORM_REPO_URL/PLATFORM_REPO_REVISION/
# TENANT_REQUESTS_REPO_URL, aşağıdaki .env source'unun ÜZERİNE
# YAZILMAMALI (.env'de bu üçü genellikle BOŞ bırakılır, bkz. .env.example)
# — önce yakala, .env'i kaynakla, sonra çağıranınkini GERİ YÜKLE (boş
# değilse).
#
# DÜZELTME (code review #11'in test EDİLİRKEN keşfedilen bir YAN bulgusu):
# `TENANT_REQUESTS_REPO_URL` bu korumaya DAHİL DEĞİLDİ — `.env`'de
# (`.env.example`'daki gibi) `TENANT_REQUESTS_REPO_URL=""` satırı olduğu
# için, ÇAĞIRANIN export ettiği GERÇEK değer bu `source .env` adımıyla
# SESSİZCE boş string'e GERİ ALINIYORDU; bu, #11'in ASIL düzeltmesini
# (SUBST_VARS'a ekleme) PRATİKTE İŞE YARAMAZ hâle getirirdi (operatör
# değişkeni export etse bile `.env` onu ezerdi). PLATFORM_REPO_URL/
# PLATFORM_REPO_REVISION İLE AYNI capture/restore desenine eklendi.
_caller_repo_url="${PLATFORM_REPO_URL:-}"
_caller_repo_rev="${PLATFORM_REPO_REVISION:-}"
_caller_tenant_requests_url="${TENANT_REQUESTS_REPO_URL:-}"
# .env İSTEĞE BAĞLI kaynaklanır — HARBOR_HOSTNAME (policies/security'nin
# ihtiyacı) buradan gelir. Yoksa o dosya sessizce ATLANIR (aşağıdaki
# "çözülmemiş değişken" güvenlik ağı), script BAŞARISIZ OLMAZ.
[[ -f "${ENV_FILE}" ]] && { set -a; source "${ENV_FILE}"; set +a; }
[[ -n "${_caller_repo_url}" ]] && PLATFORM_REPO_URL="${_caller_repo_url}"
[[ -n "${_caller_repo_rev}" ]] && PLATFORM_REPO_REVISION="${_caller_repo_rev}"
[[ -n "${_caller_tenant_requests_url}" ]] && TENANT_REQUESTS_REPO_URL="${_caller_tenant_requests_url}"

: "${PLATFORM_REPO_URL:?PLATFORM_REPO_URL export edilmeli, bkz. bu dosyanin basligindaki KULLANIM notu}"
: "${PLATFORM_REPO_REVISION:=main}"

# İçinde en az bir ${VAR} referansı geçen HER değişken adı — envsubst'e
# TÜM ortam değişkenlerini vermek yerine yalnızca BİLİNENLERİ listelemek,
# render sonrası "beklenmedik değişken KALDI mı" kontrolünü ANLAMLI kılar.
#
# DÜZELTME (code review #11): `TENANT_REQUESTS_REPO_URL` bu listede HİÇ
# YOKTU — yani operatör bu değişkeni export etse BİLE envsubst onu
# ÇÖZEMEZDİ (envsubst'e AÇIKÇA VERİLMEYEN bir değişken referansı, değer
# atanmış olsa bile OLDUĞU GİBİ bırakılır, "${TENANT_REQUESTS_REPO_URL}"
# metni OLDUĞU GİBİ kalırdı). ÖNEMLİ İNCELİK: bu değişkeni KOŞULSUZ listeye
# eklemek AYRI bir hataya yol açar — envsubst, LİSTEDEKİ ama TANIMSIZ/boş
# bir değişkeni SESSİZCE boş string'e çözer (`sourceRepos: - ` gibi GEÇERSİZ
# ama "çözülmüş görünen" YAML üretir) — bu, "çözülmemiş değişken kaldıysa
# ATLA" güvenlik ağını TAMAMEN BYPASS ederdi. Bu yüzden yalnızca değer
# GERÇEKTEN doluyken listeye eklenir; boşken listenin DIŞINDA bırakılıp
# `${TENANT_REQUESTS_REPO_URL}` metni OLDUĞU GİBİ kalması (ve aşağıdaki
# whitelist'in bunu BİLİNÇLİ bir skip olarak tanıması) sağlanır.
SUBST_VARS='$PLATFORM_REPO_URL $PLATFORM_REPO_REVISION $HARBOR_HOSTNAME $CEPH_OBJECTSTORE_NAME $VELERO_OFFSITE_S3_URL $VELERO_OFFSITE_S3_REGION $VELERO_OFFSITE_S3_BUCKET $VELERO_OFFSITE_S3_FORCE_PATH_STYLE'
[[ -n "${TENANT_REQUESTS_REPO_URL:-}" ]] && SUBST_VARS="${SUBST_VARS} \$TENANT_REQUESTS_REPO_URL"
while IFS='=' read -r key _; do
  [[ "$key" =~ ^[A-Z_]+$ ]] || continue
  SUBST_VARS="${SUBST_VARS} \$${key}"
done < "${VERSIONS_FILE}"

# DÜZELTME (code review #11): ÖNCEDEN "render sonrası çözülmemiş bir
# ${DEĞİŞKEN} kaldıysa dosyayı ATLA" kuralı HERHANGİ bir dosya için
# geçerliydi — yani tenant-requests DIŞINDA bir dosya (örn. yanlışlıkla
# yeni bir ${VAR} eklenip versions.env/SUBST_VARS'a EKLENMEDİYSE) de
# SESSİZCE atlanır, `--verify` yine "SENKRON" derdi. Artık yalnızca BU
# İKİ dosya (TENANT_REQUESTS_REPO_URL'e bağımlı, ayrı bir repo henüz
# oluşturulmadığı için BİLİNÇLİ olarak render edilemeyen) skip'e
# UYGUNDUR; listede OLMAYAN her dosyadaki çözülmemiş değişken artık
# HER ZAMAN sert bir HATADIR.
SKIP_ALLOWED_BASENAMES="05-tenant-requests-project 06-tenant-requests-appset"

FAIL="false"
SKIPPED_FILES=()

render_dir() {
  local dir="$1"
  local f base out tmp
  for f in "${dir}"/*.yaml.tpl; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f" .yaml.tpl)"
    out="${dir}/${base}.yaml"

    tmp="$(mktemp)"
    envsubst "${SUBST_VARS}" < "$f" > "$tmp"

    if grep -qE '^\s*[^#[:space:]].*\$\{[A-Z_]+\}' "$tmp"; then
      if [[ " ${SKIP_ALLOWED_BASENAMES} " == *" ${base} "* ]] && [[ "${REQUIRE_TENANT_REQUESTS}" != "true" ]]; then
        echo "  ATLANDI (TENANT_REQUESTS_REPO_URL boş, bilinçli — bkz. başlık notu): ${f}" >&2
        grep -nE '^\s*[^#[:space:]].*\$\{[A-Z_]+\}' "$tmp" | sed 's/^/    /' >&2
        SKIPPED_FILES+=("${f}")
        rm -f "$tmp"
        continue
      fi
      echo "  HATA: ${f} render sonrası hâlâ çözülmemiş değişken içeriyor:" >&2
      grep -nE '^\s*[^#[:space:]].*\$\{[A-Z_]+\}' "$tmp" | sed 's/^/    /' >&2
      [[ "${REQUIRE_TENANT_REQUESTS}" == "true" ]] && [[ " ${SKIP_ALLOWED_BASENAMES} " == *" ${base} "* ]] && \
        echo "    (--require-tenant-requests ile TENANT_REQUESTS_REPO_URL export edilmeden bu dosya render EDİLEMEZ)" >&2
      FAIL="true"
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

# DÜZELTME (Faz 12k, code review #13): `apps/02-velero.yaml.tpl`'in
# `valueFiles`'ı ÖNCEDEN ham `values.yaml.tpl`'e (envsubst edilmemiş
# ${CEPH_OBJECTSTORE_NAME} İÇEREN) işaret ediyordu — Helm'in `$values` ref
# source'u bu dosyayı OLDUĞU GİBİ git'ten okur, envsubst UYGULAMAZ. Manuel
# kurulumun (06-velero.sh, envsubst render eder) ve ArgoCD'nin GÖRDÜĞÜ
# değerler böylece FARKLIYDI — ArgoCD SONRADAN devraldığında (adoption)
# bozuk bir S3 endpoint'i uygulardı. `values.yaml.tpl`/`values-offsite.
# yaml.tpl` İÇİNDEKİ tüm değerler (CEPH_OBJECTSTORE_NAME, VELERO_OFFSITE_
# S3_*) SIR DEĞİLDİR (gerçek S3 access/secret key'ler `velero-credentials`
# Secret'ına AYRI gider, bkz. 06-velero.sh) — bu yüzden diğer Application
# manifestleriyle AYNI şekilde render edilip commit EDİLEBİLİR.
echo "Render ediliyor: platform/control-plane/velero/"
render_dir "${REPO_ROOT}/platform/control-plane/velero"

# DÜZELTME (code review #12): `apps/01-loki.yaml`/`01-tempo.yaml`'ın
# `valueFiles`'ı Velero'nun Faz 12k'DEN ÖNCEKİ HÂLİYLE AYNI hataya
# sahipti — ham `.tpl`'e işaret ediyordu, ArgoCD `$values` ref source'uyla
# bunu OLDUĞU GİBİ git'ten okur. Loki/Tempo'nun values.yaml.tpl'i
# ÖNCEDEN GERÇEK S3 SIR değerlerini (${LOKI_S3_SECRET_KEY} vb.) DOĞRUDAN
# İÇERDİĞİ için bu Velero'dakinden DAHA CİDDİYDİ — o dosyalar artık
# `extraEnv`+Secret referansına geçirildi (bkz. loki/tempo/values.yaml.tpl
# başlık yorumları, 05-observability.sh `install_loki()`/`install_tempo()`)
# ve HİÇBİR SIR İÇERMİYOR — bu yüzden Velero ile AYNI şekilde güvenle
# render edilip commit EDİLEBİLİR.
echo "Render ediliyor: platform/control-plane/observability/loki/"
render_dir "${REPO_ROOT}/platform/control-plane/observability/loki"

echo "Render ediliyor: platform/control-plane/observability/tempo/"
render_dir "${REPO_ROOT}/platform/control-plane/observability/tempo"

if [[ "${VERIFY_ONLY}" == "true" ]]; then
  if [[ "${FAIL}" == "true" ]]; then
    echo "❌ DRIFT bulundu — yukarıdaki dosyalar için bu script'i --verify OLMADAN çalıştırıp commit edin." >&2
    exit 1
  fi
  if [[ "${#SKIPPED_FILES[@]}" -gt 0 ]]; then
    # DÜZELTME (code review #11): bu dalın ÖNCEKİ hâli, atlanan dosyalar
    # olsa BİLE koşulsuz "Tüm ... SENKRON" diyordu — bu, self-servis
    # tenant GitOps akışının FİİLEN devrede OLMADIĞINI gizleyen yanıltıcı
    # bir "her şey yolunda" sinyaliydi. Artık atlama AÇIKÇA rapor ediliyor
    # ve genel çıkış "kısmi" olarak işaretleniyor (exit kodu YİNE 0 —
    # bootstrap-öncesi bu durum GEÇERLİ bir ARA durumdur, ama sessiz
    # DEĞİLDİR; tam canlıya geçiş kontrolü için `--require-tenant-requests`
    # kullanın).
    echo "⚠️  Render edilebilir TÜM dosyalar SENKRON, AMA ${#SKIPPED_FILES[@]} dosya TENANT_REQUESTS_REPO_URL boş olduğu için ATLANDI (tenant self-servis GitOps akışı HENÜZ DEVREDE DEĞİL):"
    printf '    - %s\n' "${SKIPPED_FILES[@]}"
    echo "    tenant-requests reposu kurulduğunda: TENANT_REQUESTS_REPO_URL export edip --require-tenant-requests ile yeniden çalıştırın."
  else
    echo "✅ Tüm .yaml.tpl → .yaml render'ları SENKRON (tenant-requests DAHİL)"
  fi
else
  echo "✅ Render tamamlandı. ${REPO_ROOT}'ta 'git status' ile yeni/değişen .yaml dosyalarını inceleyip commit edin."
  if [[ "${#SKIPPED_FILES[@]}" -gt 0 ]]; then
    echo "⚠️  ${#SKIPPED_FILES[@]} dosya TENANT_REQUESTS_REPO_URL boş olduğu için ATLANDI — yukarıya bakın."
  fi
fi
