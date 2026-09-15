#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
python3 - "${DIR}/../../control-plane/observability/resources/vault-tls-monitor.yaml" "${work}/vault.rules.yaml" <<'PY'
import sys,yaml
rules=next(d['spec'] for d in yaml.safe_load_all(open(sys.argv[1])) if d and d['kind']=='PrometheusRule')
with open(sys.argv[2],'w') as f: yaml.safe_dump(rules,f)
PY
cp "${DIR}/vault-alerts.test.yaml" "${work}/tests.yaml"
cd "${work}"
if command -v promtool >/dev/null; then
  promtool check rules vault.rules.yaml
  promtool test rules tests.yaml
else
  docker run --rm --entrypoint /bin/promtool -v "${work}:/work:ro" -w /work \
    prom/prometheus:v2.55.0 test rules tests.yaml
fi
