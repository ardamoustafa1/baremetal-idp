#!/usr/bin/env bash
# =============================================================================
# Haftalık tenant özeti — maliyet (OpenCost) + kaynak kullanımı (ResourceQuota)
# + sertifika durumu (cert-manager). Faz 9, görev madde 6.
#
# BASİT TUTULDU (görev metninin isteği): Prometheus'a doğrudan PromQL sorgusu
# YOK — ResourceQuota zaten `requests.cpu/requests.memory` KULLANIMINI
# (status.used) API sunucusundan anında verir; ayrı bir metrik sorgusuna
# gerek yoktur. Maliyet İÇİN OpenCost'un kendi allocation API'si kullanılır
# (Prometheus'u OpenCost zaten dahili olarak sorguluyor — burada tekrar
# etmiyoruz).
#
# ÇIKTI: her tenant namespace'inde `weekly-report` adlı bir ConfigMap
# (data: report.md) — Backstage'in `catalog-info` ConfigMap'iyle AYNI
# keşfedilebilirlik deseni (bkz. compositions/tenant/function.k #8): elle bir
# dağıtım adımı YOK, rapor kubectl/Backstage ile okunur. CronJob log'ları da
# aynı içeriği STDOUT'a yazar (kubectl logs ile hızlı bakış için).
#
# ÇALIŞTIRMA BİÇİMİ: platform/control-plane/observability/weekly-report/
# cronjob.yaml, bu dosyayı bir ConfigMap olarak mount eder ve `bash
# /scripts/report.sh` ile haftada bir çalıştırır (bkz. cronjob.yaml).
# =============================================================================
set -Eeuo pipefail

OPENCOST_URL="${OPENCOST_URL:-http://opencost.opencost.svc.cluster.local:9003}"
WINDOW="${REPORT_WINDOW:-7d}"

log() { printf '[weekly-report] %s\n' "$*"; }

# --- Tenant namespace'lerini bul (compositions/tenant/function.k'nin
# ürettiği zorunlu etiketle) -------------------------------------------------
mapfile -t TENANT_NAMESPACES < <(
  kubectl get namespace \
    -l platform.internal/managed-by=crossplane \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

if (( ${#TENANT_NAMESPACES[@]} == 0 )); then
  log "Hiç tenant namespace bulunamadı (label: platform.internal/managed-by=crossplane) — çıkılıyor."
  exit 0
fi

log "Bulunan tenant sayısı: ${#TENANT_NAMESPACES[@]}"

# --- Maliyet: OpenCost allocation API, cost-center etiketine göre gruplu ---
# (madde 5'in kabul kriteri: rapor cost-center'a göre DOĞRU gruplanmalı —
# bu yüzden `aggregate=label:cost-center` ile TEK bir istek yapılıyor,
# tenant başına ayrı sorgu YERİNE; sonuç sonra namespace'e göre eşleştirilir.)
cost_json="$(curl -sf --max-time 20 \
  "${OPENCOST_URL}/allocation/compute?window=${WINDOW}&aggregate=label:cost-center&accumulate=true" \
  || echo '{}')"

cost_for_namespace() {
  local cost_center="$1"
  # OpenCost'un cost-center bazlı toplamı, namespace ayrımı OLMADAN geldiği
  # için (aggregate=label:cost-center), bu değer o cost-center'a bağlı TÜM
  # namespace'lerin TOPLAMIdır — tek-namespace/tek-cost-center kurulumlarda
  # (conventions.md §3.1: bir cost-center genelde bir tenant'a atanır) doğru
  # tenant bazlı rakamı verir; birden çok tenant AYNI cost-center'ı
  # paylaşıyorsa bu TOPLAM olarak yorumlanmalıdır (rapor bunu açıkça belirtir).
  jq -r --arg cc "${cost_center}" \
    '(.data[0][$cc].totalCost // "n/a") | if type == "number" then (.*10000|round/10000|tostring) else . end' \
    <<<"${cost_json}" 2>/dev/null || echo "n/a"
}

# --- Tek tenant için rapor üret --------------------------------------------
build_report() {
  local ns="$1"
  local cost_center owner tier environment
  cost_center="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.platform\.internal/cost-center}' 2>/dev/null || echo "?")"
  owner="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.platform\.internal/owner}' 2>/dev/null || echo "?")"
  tier="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.platform\.internal/tier}' 2>/dev/null || echo "?")"
  environment="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.platform\.internal/environment}' 2>/dev/null || echo "?")"

  local cost
  cost="$(cost_for_namespace "$cost_center")"

  local rq_json cpu_used cpu_hard mem_used mem_hard pods_used pods_hard
  rq_json="$(kubectl get resourcequota tenant-quota -n "$ns" -o json 2>/dev/null || echo '{}')"
  cpu_used="$(jq -r '.status.used["requests.cpu"] // "n/a"' <<<"${rq_json}")"
  cpu_hard="$(jq -r '.status.hard["requests.cpu"] // "n/a"' <<<"${rq_json}")"
  mem_used="$(jq -r '.status.used["requests.memory"] // "n/a"' <<<"${rq_json}")"
  mem_hard="$(jq -r '.status.hard["requests.memory"] // "n/a"' <<<"${rq_json}")"
  pods_used="$(jq -r '.status.used["pods"] // "n/a"' <<<"${rq_json}")"
  pods_hard="$(jq -r '.status.hard["pods"] // "n/a"' <<<"${rq_json}")"

  local now_epoch cert_lines
  now_epoch="$(date -u +%s)"
  cert_lines="$(kubectl get certificate -n "$ns" -o json 2>/dev/null | jq -r --argjson now "${now_epoch}" '
    if (.items | length) == 0 then
      "  - (bu tenant icin Certificate kaynagi yok)"
    else
      .items[] | (
        .metadata.name as $name
        | ((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "Unknown") as $ready
        | (.status.notAfter // "") as $notAfter
        | (if $notAfter == "" then "?"
           else ((($notAfter | fromdateiso8601) - $now) / 86400 | floor | tostring)
           end) as $daysLeft
        | "  - \($name): Ready=\($ready), kalan gun=\($daysLeft)"
      )
    end' 2>/dev/null || echo "  - (Certificate durumu okunamadı)")"

  cat <<EOF
# Haftalık Özet — ${ns}

- **Tenant**: ${owner} (${environment}, tier=${tier})
- **Cost-center**: ${cost_center}
- **Rapor penceresi**: son ${WINDOW}
- **Tarih**: $(date -u '+%Y-%m-%d %H:%M UTC')

## Maliyet (OpenCost, cost-center bazlı)
- Tahmini maliyet (\$): ${cost}
  > Not: aynı cost-center'ı paylaşan başka tenant varsa bu rakam PAYLAŞILAN toplamdır.

## Kaynak kullanımı (ResourceQuota)
- CPU: ${cpu_used} / ${cpu_hard}
- Bellek: ${mem_used} / ${mem_hard}
- Pod: ${pods_used} / ${pods_hard}

## Sertifika durumu (cert-manager)
${cert_lines}
EOF
}

for ns in "${TENANT_NAMESPACES[@]}"; do
  log "Rapor üretiliyor: ${ns}"
  report="$(build_report "${ns}")"
  echo "${report}"
  echo "---"

  kubectl create configmap weekly-report \
    -n "${ns}" \
    --from-literal="report.md=${report}" \
    --dry-run=client -o yaml \
    | kubectl label -f - --local -o yaml \
        platform.internal/managed-by=weekly-report-cronjob \
    | kubectl apply -f -
done

log "Tamamlandı: ${#TENANT_NAMESPACES[@]} tenant için rapor üretildi."
