#!/usr/bin/env bash
# =============================================================================
# `function.k`'nin SABİTLENMİŞ `_harborHostname`'inin (KCL'in shell ortam
# değişkenlerine erişimi YOK — bkz. function.k başlık yorumu) GERÇEK
# `HARBOR_HOSTNAME` (platform/underlay/.env, PLATFORM_BASE_DOMAIN'e bağlı)
# değeriyle hâlâ EŞLEŞTİĞİNİ doğrular — code review #14'ün çözümü.
#
# NEDEN GEREKLİ: `_harborHostname` yalnızca BİR KEZ, `.env.example`'ın
# O ANKİ varsayılanıyla ("apps.example.internal") EŞLEŞECEK şekilde
# yazıldı. PLATFORM_BASE_DOMAIN gerçek bir dağıtımda DEĞİŞTİRİLİRSE (neredeyse
# HER ZAMAN değişir — "apps.example.internal" gerçek bir domain DEĞİLDİR),
# `_harborHostname` GÜNCELLENMEZSE composition'ın ürettiği `pgImage`
# YANLIŞ bir Harbor host'una işaret eder — Postgres Cluster'ı `ImagePullBackOff`
# ile SESSİZCE takılır (Faz 12i'nin "Harbor kendi imajını reddediyordu"
# bulgusuyla AYNI kök neden sınıfı: statik bir varsayımın gerçek ortam
# değeriyle SESSİZCE SAPMASI).
#
# BU SCRIPT NE YAPMAZ: gerçek bir Harbor registry'sine karşı imajın VAR
# OLDUĞUNU/imzalı OLDUĞUNU DOĞRULAMAZ (bu ortamda gerçek bir Harbor/cosign
# YOK) — bkz. aşağıdaki `verify-harbor-image-exists.sh` (yalnızca GERÇEK
# bir Harbor'a karşı, İSTEĞE BAĞLI, elle çalıştırılır). Bu script yalnızca
# İKİ STATİK DEĞERİN (function.k'nin sabiti ile .env'in gerçek değeri)
# SENKRON olduğunu doğrular — `verify-pss-exemption-sync.sh` İLE AYNI
# desen.
#
# KULLANIM
#   bash platform/compositions/postgresql/tests/verify-harbor-image-config.sh
#   PLATFORM_BASE_DOMAIN=... bash .../verify-harbor-image-config.sh   # .env'i geçersiz kıl
# =============================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DIR}/../../.." && pwd)"
ENV_FILE="${REPO_ROOT}/platform/underlay/.env"
ENV_EXAMPLE_FILE="${REPO_ROOT}/platform/underlay/.env.example"

# PLATFORM_BASE_DOMAIN çağıran tarafından zaten export edilmişse ONU
# KORU (verify-pss-exemption-sync.sh'in .env source'u korurken çağıranı
# ezmeme desenindeki AYNI fikir) — yoksa .env, o da yoksa .env.example'dan
# oku.
if [[ -z "${PLATFORM_BASE_DOMAIN:-}" ]]; then
  if [[ -f "${ENV_FILE}" ]]; then
    PLATFORM_BASE_DOMAIN="$(grep -E '^PLATFORM_BASE_DOMAIN=' "${ENV_FILE}" | head -1 | cut -d'=' -f2- | tr -d '"')"
  elif [[ -f "${ENV_EXAMPLE_FILE}" ]]; then
    PLATFORM_BASE_DOMAIN="$(grep -E '^PLATFORM_BASE_DOMAIN=' "${ENV_EXAMPLE_FILE}" | head -1 | cut -d'=' -f2- | tr -d '"')"
    echo "UYARI: platform/underlay/.env yok, .env.example'daki varsayılan kullanılıyor." >&2
  fi
fi

: "${PLATFORM_BASE_DOMAIN:?PLATFORM_BASE_DOMAIN belirlenemedi (.env/.env.example yok ve export edilmedi)}"

expected_harbor_hostname="harbor.${PLATFORM_BASE_DOMAIN}"

actual_harbor_hostname="$(python3 - "${DIR}/function.k" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'_harborHostname\s*=\s*"([^"]+)"', text)
sys.exit("function.k'de _harborHostname bulunamadı") if not m else print(m.group(1))
PY
)"

if [[ "${expected_harbor_hostname}" == "${actual_harbor_hostname}" ]]; then
  echo "✅ function.k'nin _harborHostname'i (${actual_harbor_hostname}) HARBOR_HOSTNAME ile SENKRON (PLATFORM_BASE_DOMAIN=${PLATFORM_BASE_DOMAIN})"
  exit 0
else
  echo "❌ DRIFT: function.k'nin _harborHostname'i ('${actual_harbor_hostname}') GERÇEK HARBOR_HOSTNAME'den ('${expected_harbor_hostname}', PLATFORM_BASE_DOMAIN='${PLATFORM_BASE_DOMAIN}'den türetilir) FARKLI!" >&2
  echo "   function.k'deki _harborHostname sabitini '${expected_harbor_hostname}' olarak güncelleyip composition.yaml'ı YENİDEN üretin (bkz. verify-sync.sh)." >&2
  exit 1
fi
