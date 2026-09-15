#!/usr/bin/env bash
# =============================================================================
# examples/ altındaki PostgreSQLInstance CLAIM'lerini `crossplane render` ile
# render eder. Aynı desen: compositions/tenant/tests/render-examples.sh.
#
# NEDEN CLAIM'DEN DEĞİL: `crossplane render`, Composition'ın compositeTypeRef'i
# (XPostgreSQLInstance) ile eşleşen bir composite kaynak bekler — claim'i
# (PostgreSQLInstance) DEĞİL. Bu script claim'i XR'a çevirip render eder.
#
# Kullanım:
#   ./render-examples.sh                # tüm examples/*.yaml
#   ./render-examples.sh --check         # yalnızca hata var mı kontrol eder (CI)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${COMP_DIR}/../../.." && pwd)"
OUT_DIR="${REPO_ROOT}/platform/docs/examples-output"
FUNCTIONS_FILE="${SCRIPT_DIR}/functions.yaml"

CHECK_ONLY="false"
[[ "${1:-}" == "--check" ]] && CHECK_ONLY="true"

command -v crossplane >/dev/null 2>&1 || { echo "FAIL: 'crossplane' CLI yok (brew install crossplane)"; exit 1; }
docker info >/dev/null 2>&1 || echo "UYARI: Docker daemon erişilemez — function-kcl/function-auto-ready Docker container'ı ÇALIŞTIRIR, olmadan render BAŞARISIZ olur."

mkdir -p "${OUT_DIR}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail=0
for claim in "${COMP_DIR}"/examples/postgresql-*.yaml; do
  name="$(basename "${claim}" .yaml)"
  xr="${work}/${name}-xr.yaml"

  # Claim → XR: kind/apiVersion aynı grup, `PostgreSQLInstance` →
  # `XPostgreSQLInstance`, namespace düşer.
  python3 - "${claim}" "${xr}" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))
doc["kind"] = "XPostgreSQLInstance"
doc["metadata"] = {"name": doc["metadata"]["name"]}
yaml.safe_dump(doc, open(dst, "w"), sort_keys=False)
PY

  echo "=== ${name} ==="
  out="${OUT_DIR}/${name}.rendered.yaml"
  if crossplane render "${xr}" "${COMP_DIR}/composition.yaml" "${FUNCTIONS_FILE}" \
       --include-full-xr -r > "${out}.tmp" 2>"${work}/${name}.err"; then
    mv "${out}.tmp" "${out}"
    doc_count="$(grep -c '^kind:' "${out}" || true)"
    echo "  ✅ render OK — ${out} (${doc_count} doküman)"
  else
    echo "  ❌ render BAŞARISIZ:"
    sed 's/^/     /' "${work}/${name}.err"
    fail=1
  fi
done

exit "${fail}"
