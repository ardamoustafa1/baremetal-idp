#!/usr/bin/env bash
# =============================================================================
# function.k ile composition.yaml'ın gömülü KCL kaynağının SENKRON olduğunu
# doğrular. İki dosya elle senkron tutulur (bkz. composition.yaml başlığı);
# bu script drift'i CI'da/lokal olarak YAKALAR — sessizce birbirinden
# uzaklaşmalarını ENGELLER.
# =============================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

extracted="$(python3 - "${DIR}/composition.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
src = doc["spec"]["pipeline"][0]["input"]["spec"]["source"]
sys.stdout.write(src)
PY
)"

canonical="$(cat "${DIR}/function.k")"

# YAML block scalar (|) baştaki/sondaki whitespace'i normalize eder;
# karşılaştırmadan önce her iki tarafı da trim ediyoruz.
if [[ "$(printf '%s' "${extracted}" | sed -e 's/[[:space:]]*$//')" \
   == "$(printf '%s' "${canonical}" | sed -e 's/[[:space:]]*$//')" ]]; then
  echo "✅ function.k ve composition.yaml'ın gömülü KCL kaynağı SENKRON"
  exit 0
else
  echo "❌ DRIFT: function.k ile composition.yaml'daki kaynak farklı!"
  echo "   composition.yaml'ı yeniden üretin (function.k'yi 12 boşlukla girintileyip"
  echo "   spec.pipeline[0].input.spec.source altına yapıştırın)."
  diff <(printf '%s' "${extracted}") <(printf '%s' "${canonical}") | head -30
  exit 1
fi
