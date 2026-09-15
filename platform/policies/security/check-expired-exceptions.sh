#!/usr/bin/env bash
# =============================================================================
# `platform.internal/pss-exception-review-date`si GEÇMİŞ PolicyException'ları
# raporlar — teknik borç #32'nin çözümü. Kyverno'nun KENDİSİ bu tarihi
# TAKİP ETMEZ (yalnızca varlığını zorunlu kılar, bkz. 02-require-pss-
# restricted-clusterwide.yaml'ın exceptions-require-justification kuralı) —
# bu script GERÇEK süre takibini yapar.
#
# ÇALIŞTIRMA: elle (`bash check-expired-exceptions.sh`) veya bir CronJob'a
# (`observability/weekly-report` ile AYNI desende) bağlanabilir — bu görev
# kapsamında yalnızca script yazıldı, CronJob'a BAĞLANMADI (istenirse
# `platform/control-plane/observability/weekly-report/cronjob.yaml`'daki
# desen tekrarlanarak eklenebilir).
# =============================================================================
set -Eeuo pipefail

TODAY_EPOCH="$(date -u +%s)"
found_expired=0

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  name="$(echo "${line}" | jq -r '.metadata.name')"
  namespace="$(echo "${line}" | jq -r '.metadata.namespace')"
  review_date="$(echo "${line}" | jq -r '.metadata.annotations["platform.internal/pss-exception-review-date"] // empty')"

  if [[ -z "${review_date}" ]]; then
    echo "⚠️  ${namespace}/${name}: review-date annotation'ı YOK (nasıl var olabildi? — exceptions-require-justification kuralı bunu engellemeliydi)"
    continue
  fi

  review_epoch="$(date -u -d "${review_date}" +%s 2>/dev/null || date -u -j -f "%Y-%m-%d" "${review_date}" +%s 2>/dev/null || echo "")"
  if [[ -z "${review_epoch}" ]]; then
    echo "⚠️  ${namespace}/${name}: review-date ('${review_date}') geçersiz format (YYYY-MM-DD bekleniyor)"
    continue
  fi

  if (( review_epoch < TODAY_EPOCH )); then
    days_overdue=$(( (TODAY_EPOCH - review_epoch) / 86400 ))
    echo "❌ ${namespace}/${name}: review-date (${review_date}) ${days_overdue} gün GEÇTİ — gözden geçirin veya kaldırın"
    found_expired=1
  else
    echo "✅ ${namespace}/${name}: review-date (${review_date}) hâlâ geçerli"
  fi
done < <(kubectl get policyexception -A -o json 2>/dev/null | jq -c '.items[]')

exit "${found_expired}"
