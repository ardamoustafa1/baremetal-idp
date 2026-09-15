# =============================================================================
# MetalLB adres havuzu — ŞABLON
#
# ${METALLB_IP_RANGE} .env'den gelir. Bu repoda hiçbir gerçek IP yoktur.
#
# Havuz için gereklilikler (ağ ekibiyle teyit edin):
#   - Node'ların bulunduğu L2 broadcast domain'inde olmalı (L2 mode ARP kullanır)
#   - DHCP kapsamı DIŞINDA olmalı — çakışma sessiz ve teşhisi zor arıza üretir
#   - Havuzdaki hiçbir adres başka bir cihaza atanmamış olmalı
#
# PLATFORM_CONTEXT.md açık karar #1 bu değer girilince kapanır.
# =============================================================================
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${METALLB_POOL_NAME}
  namespace: metallb-system
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
spec:
  addresses:
${METALLB_ADDRESSES_YAML_LIST}
  # true: LoadBalancer Service'ler havuzu istemeden IP alır.
  # false: Service, metallb.universe.tf/address-pool annotation'ı ile
  #        havuzu açıkça istemek zorunda (tenant'lara açılırken tercih edilir).
  autoAssign: ${METALLB_AUTO_ASSIGN}
  # .0 ve .255 ile biten adresleri atama — eski istemcilerde sorun çıkarır
  avoidBuggyIPs: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${METALLB_POOL_NAME}-l2
  namespace: metallb-system
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
spec:
  ipAddressPools:
    - ${METALLB_POOL_NAME}
  # interfaces: [] bırakıldı → MetalLB uygun arayüzü kendi seçer.
  # Node'larda birden fazla NIC varsa burada açıkça belirtin.
