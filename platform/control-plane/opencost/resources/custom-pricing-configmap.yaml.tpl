# =============================================================================
# OpenCost manuel (bare-metal) fiyatlandırma modeli.
#
# OpenCost'un "custom pricing" mekanizması: bu ConfigMap'in anahtarları
# (CPU/RAM/storage, saatlik $ birimiyle) `CUSTOM_PRICING_CONFIGMAP_NAME` env
# değişkeniyle (values.yaml) exporter'a bağlanır — OpenCost her allocation
# hesaplamasında cloud-provider API'si yerine BU sabit birim fiyatları
# kullanır. Kaynak: OpenCost docs "Custom Pricing" (on-prem/bare-metal kurulum
# senaryosu resmi olarak bunu önerir; AWS/GCP/Azure billing entegrasyonlarının
# HİÇBİRİ bare-metal'de geçerli değildir).
#
# Bu bir Secret DEĞİL, ConfigMap'tir (fiyat bilgisi kimlik bilgisi değildir)
# ama yine de .env'den envsubst ile render edilir çünkü donanım amortismanı +
# elektrik + bakım maliyetine göre HESAPLANAN, operatöre özgü bir değerdir
# (versions.env'e değil .env'e ait — bkz. opencost/values.yaml yorumu).
# =============================================================================
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencost-custom-pricing
  namespace: opencost
  labels:
    platform.internal/managed-by: observability-bootstrap
    platform.internal/layer: control-plane
data:
  CPU: "${OPENCOST_CPU_HOURLY_COST}"
  spotCPU: "${OPENCOST_CPU_HOURLY_COST}"
  RAM: "${OPENCOST_RAM_HOURLY_COST}"
  spotRAM: "${OPENCOST_RAM_HOURLY_COST}"
  storage: "${OPENCOST_STORAGE_HOURLY_COST}"
  GPU: "0"
  zoneNetworkEgress: "0"
  regionNetworkEgress: "0"
  internetNetworkEgress: "0"
