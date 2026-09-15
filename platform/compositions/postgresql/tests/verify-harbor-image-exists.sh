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
#   COSIGN_PUBLIC_KEY=/path/to/cosign.pub bash .../verify-harbor-image-exists.sh --require-signature
#     # ÜRETİM MODU (code review #11): anahtar + cosign ZORUNLU, HERHANGİ
#     # biri eksikse (veya imza doğrulanamazsa) script BAŞARISIZ olur —
#     # bkz. aşağıdaki DÜZELTME notu.
# =============================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DIR}/../../.." && pwd)"
ENV_FILE="${REPO_ROOT}/platform/underlay/.env"

# DÜZELTME (code review #11, YÜKSEK): bu script ÖNCEDEN imza doğrulamasını
# YALNIZCA `COSIGN_PUBLIC_KEY` VE `cosign` İKİSİ DE mevcutsa yapıyordu —
# biri EKSİKSE imza kontrolü SESSİZCE ATLANIYORDU ve script yalnızca imaj
# VARLIĞINA bakıp BAŞARILI (exit 0) çıkabiliyordu. Bu, `require-signed-
# images` Kyverno politikasının (imzasız imajları HER ZAMAN reddeden)
# GERÇEK davranışıyla ÇELİŞEN yanlış bir "yeşil tik" üretiyordu — bu ön
# kontrol geçse bile GERÇEK deployment Kyverno tarafından REDDEDİLEBİLİRDİ.
# `--require-signature` bayrağı (VEYA `REQUIRE_SIGNATURE=true` env
# değişkeni) bunu ÜRETİM MODUNA çevirir: anahtar/cosign eksikse VEYA
# HERHANGİ bir imaj imzasız/doğrulanamazsa script BAŞARISIZ olur — "imza
# kontrolü ATLANDI" ASLA "başarılı" ile KARIŞTIRILMAZ.
REQUIRE_SIGNATURE="${REQUIRE_SIGNATURE:-false}"
for _arg in "$@"; do
  [[ "${_arg}" == "--require-signature" ]] && REQUIRE_SIGNATURE="true"
done

if [[ -z "${HARBOR_HOSTNAME:-}" && -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}"; set +a
fi
: "${HARBOR_HOSTNAME:?HARBOR_HOSTNAME export edilmeli (veya platform/underlay/.env icinde tanimli olmali)}"

if [[ "${REQUIRE_SIGNATURE}" == "true" ]]; then
  [[ -n "${COSIGN_PUBLIC_KEY:-}" ]] || { echo "HATA: --require-signature verildi ama COSIGN_PUBLIC_KEY export edilmemiş." >&2; exit 1; }
  [[ -f "${COSIGN_PUBLIC_KEY}" ]] || { echo "HATA: --require-signature verildi ama COSIGN_PUBLIC_KEY dosyası bulunamadı: ${COSIGN_PUBLIC_KEY}" >&2; exit 1; }
  command -v cosign >/dev/null 2>&1 || { echo "HATA: --require-signature verildi ama cosign kurulu değil." >&2; exit 1; }
fi

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
  else
    signature_skipped="true"
    if [[ "${REQUIRE_SIGNATURE}" == "true" ]]; then
      # Bu dala normalde HİÇ ULAŞILMAMALI — üstteki erken precondition
      # kontrolü zaten COSIGN_PUBLIC_KEY/cosign eksikse script'i BAŞLAMADAN
      # durdurur. Yine de bir savunma katmanı olarak burada da FAIL ediliyor.
      echo "  ❌ ${ref}: --require-signature ile imza kontrolü ATLANAMAZ ama COSIGN_PUBLIC_KEY/cosign eksik." >&2
      fail="true"
    fi
  fi
done

if [[ "${fail}" == "true" ]]; then
  echo "❌ Bir veya daha fazla PostgreSQL imajı Harbor'da eksik/imzasız — provizyon ÖNCESİ bunu düzeltin." >&2
  exit 1
fi

if [[ "${signature_skipped:-false}" == "true" ]]; then
  # DÜZELTME (code review #11): bu script ÖNCEDEN imza kontrolü
  # ATLANDIĞINDA (COSIGN_PUBLIC_KEY/cosign eksik) KOŞULSUZ "✅ Tüm
  # imajlar mevcut" diyordu — bu, İMZA DOĞRULANMADIĞI GERÇEĞİNİ gizleyen
  # yanıltıcı bir başarı mesajıydı (Kyverno'nun require-signed-images
  # politikası imzasız imajı GERÇEK deployment'ta REDDEDEBİLİR). Artık
  # bu durum ⚠️ ile AÇIKÇA raporlanıyor, asla düz "✅" ile karışmıyor.
  echo "⚠️  Tüm PostgreSQL imajları (${#tags[@]}) Harbor'da mevcut, AMA imza kontrolü ATLANDI (COSIGN_PUBLIC_KEY/cosign eksik) — Kyverno'nun require-signed-images politikası GERÇEK deployment'ta bunları REDDEDEBİLİR. Üretim öncesi COSIGN_PUBLIC_KEY export edip --require-signature ile YENİDEN çalıştırın."
  exit 0
fi
echo "✅ Tüm PostgreSQL imajları (${#tags[@]}) Harbor'da mevcut VE imzaları doğrulandı."
