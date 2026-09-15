#!/usr/bin/env bash
# =============================================================================
# GERÇEK bir Harbor registry'sine karşı, composition'ın (`function.k`)
# üreteceği HER PostgreSQL sürümü imajının (`_pgImageTags`) GERÇEKTEN
# VAR OLDUĞUNU ve (varsa) cosign imzasının DOĞRULANDIĞINI kontrol eder —
# code review #14'ün ikinci yarısı ("registry erişimi ve imza
# doğrulamasını provisioning ön kontrolüne almak").
#
# BU SCRIPT `verify-harbor-image-config.sh`'DEN FARKLIDIR: o script yalnızca
# İKİ STATİK DEĞERİ (function.k'nin sabiti / .env'in gerçek değeri)
# karşılaştırır (her zaman, saniyeler içinde, ağ erişimi GEREKTİRMEDEN
# çalışır — CI'da HER PR'da çalıştırılır). BU script ise GERÇEK bir ağ
# çağrısı yapar (`crane`/`skopeo`/`docker manifest inspect` — hangisi
# kuruluysa) — bu yüzden yalnızca GERÇEK bir Harbor'a erişimi olan bir
# ortamda (CI'DA DEĞİL — bu ortamda gerçek bir Harbor/cosign YOK, bkz.
# PLATFORM_CONTEXT.md) İSTEĞE BAĞLI, ELLE çalıştırılmak üzere tasarlandı.
# CI'a BİLİNÇLİ OLARAK wired EDİLMEDİ (sahte bir "yeşil tik" üretmemek
# için) — provizyon ÖNCESİ bir operatör kontrol listesi maddesi olarak
# `platform/compositions/postgresql/README.md`'ye eklendi.
#
# KULLANIM
#   export HARBOR_HOSTNAME=harbor.example.internal   # (veya .env'den okunur)
#   bash platform/compositions/postgresql/tests/verify-harbor-image-exists.sh
#   COSIGN_PUBLIC_KEY=/path/to/cosign.pub bash .../verify-harbor-image-exists.sh   # imza da doğrulanır
# =============================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DIR}/../../.." && pwd)"
ENV_FILE="${REPO_ROOT}/platform/underlay/.env"

if [[ -z "${HARBOR_HOSTNAME:-}" && -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
fi
: "${HARBOR_HOSTNAME:?HARBOR_HOSTNAME export edilmeli (veya platform/underlay/.env icinde tanimli olmali)}"

# function.k'deki _pgImageTags map'ini (sürüm → tag) statik olarak çıkar —
# KCL çalıştırmadan basit bir regex ile (bu dosyanın format İSTİKRARINA
# bağımlı — değişirse bu script de güncellenmelidir).
mapfile -t tags < <(python3 - "${DIR}/function.k" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'_pgImageTags\s*=\s*\{(.*?)\}', text, re.S)
if not m:
    sys.exit("function.k'de _pgImageTags bulunamadı")
for line in m.group(1).splitlines():
    tm = re.search(r'"([^"]+)"\s*=\s*"([^"]+)"', line)
    if tm:
        print(tm.group(2))
PY
)
[[ "${#tags[@]}" -gt 0 ]] || { echo "HATA: _pgImageTags'ten hiçbir tag çıkarılamadı." >&2; exit 1; }

image_repo="${HARBOR_HOSTNAME}/cloudnative-pg/postgresql"

tool=""
for candidate in crane skopeo docker; do
  command -v "${candidate}" >/dev/null 2>&1 && { tool="${candidate}"; break; }
done
[[ -n "${tool}" ]] || { echo "HATA: crane/skopeo/docker'dan hiçbiri kurulu değil — bu script'i çalıştıramaz." >&2; exit 1; }
echo "Kullanılan araç: ${tool}"

fail="false"
for tag in "${tags[@]}"; do
  ref="${image_repo}:${tag}"
  echo "Kontrol ediliyor: ${ref}"
  ok="false"
  case "${tool}" in
    crane)  crane manifest "${ref}" >/dev/null 2>&1 && ok="true" ;;
    skopeo) skopeo inspect "docker://${ref}" >/dev/null 2>&1 && ok="true" ;;
    docker) docker manifest inspect "${ref}" >/dev/null 2>&1 && ok="true" ;;
  esac
  if [[ "${ok}" == "true" ]]; then
    echo "  ✅ ${ref} Harbor'da mevcut"
  else
    echo "  ❌ ${ref} Harbor'da BULUNAMADI — mirror'lanmamış olabilir (bkz. compositions/postgresql/README.md)" >&2
    fail="true"
    continue
  fi

  if [[ -n "${COSIGN_PUBLIC_KEY:-}" ]] && command -v cosign >/dev/null 2>&1; then
    if cosign verify --key "${COSIGN_PUBLIC_KEY}" "${ref}" >/dev/null 2>&1; then
      echo "  ✅ ${ref} cosign imzası DOĞRULANDI"
    else
      echo "  ❌ ${ref} cosign imzası DOĞRULANAMADI (require-signed-images politikası bu imajı REDDEDER)" >&2
      fail="true"
    fi
  fi
done

if [[ "${fail}" == "true" ]]; then
  echo "❌ Bir veya daha fazla PostgreSQL imajı Harbor'da eksik/imzasız — provizyon ÖNCESİ bunu düzeltin." >&2
  exit 1
fi
echo "✅ Tüm PostgreSQL imajları (${#tags[@]}) Harbor'da mevcut."
