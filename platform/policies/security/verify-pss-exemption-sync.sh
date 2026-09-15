#!/usr/bin/env bash
# =============================================================================
# `02-require-pss-restricted-clusterwide.yaml`'ın `exclude` listesi ile
# `pod-security-admission-configuration.yaml`'ın `exemptions.namespaces`
# listesinin AYNI namespace kümesini içerdiğini doğrular — teknik borç #30'un
# çözümü (function.k/composition.yaml drift kontrolüyle AYNI desen).
# =============================================================================
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kyverno_list="$(python3 - "${DIR}/02-require-pss-restricted-clusterwide.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
names = doc["spec"]["rules"][0]["exclude"]["any"][0]["resources"]["names"]
print("\n".join(sorted(names)))
PY
)"

admission_list="$(python3 - "${DIR}/pod-security-admission-configuration.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
names = doc["plugins"][0]["configuration"]["exemptions"]["namespaces"]
print("\n".join(sorted(names)))
PY
)"

if [[ "${kyverno_list}" == "${admission_list}" ]]; then
  echo "✅ PSS istisna listeleri SENKRON ($(echo "${kyverno_list}" | wc -l | tr -d ' ') namespace)"
  exit 0
else
  echo "❌ DRIFT: Kyverno exclude listesi ile AdmissionConfiguration exemptions listesi FARKLI!"
  diff <(echo "${kyverno_list}") <(echo "${admission_list}")
  exit 1
fi
