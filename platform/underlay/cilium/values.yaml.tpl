# =============================================================================
# Cilium — L2 Underlay CNI
# ADR-0001 Karar 2.2
#
# Bu dosya bir ŞABLONdur. ${VAR} yerlerini script envsubst ile doldurur.
# Gerçek IP/host bilgisi .env'den gelir; bu dosyada hardcoded değer YOKTUR.
#
# ÖN KOŞUL: cluster kubeadm ile `--skip-phases=addon/kube-proxy` kullanılarak
# kurulmuş olmalı. kube-proxy kuruluysa önce kaldırın (README "Ön koşullar").
# =============================================================================

# --- kube-proxy replacement --------------------------------------------------
# kube-proxy olmadığı için Cilium API server'a nasıl ulaşacağını bilmek zorunda.
# Bu iki değer OLMADAN kurulum sessizce başarısız olur (agent CrashLoop).
kubeProxyReplacement: true
k8sServiceHost: "${K8S_API_SERVER_HOST}"
k8sServicePort: "${K8S_API_SERVER_PORT}"

# eBPF servis yük dengeleme
socketLB:
  enabled: true
nodePort:
  enabled: true
externalIPs:
  enabled: true
hostPort:
  enabled: true

# --- IPAM / routing ----------------------------------------------------------
ipam:
  mode: kubernetes
  operator:
    clusterPoolIPv4PodCIDRList:
      - "${CLUSTER_POD_CIDR}"

# Bare-metal, tek L2 segment → tünelsiz (native routing) en düşük overhead.
# Node'lar farklı L2 segmentlerindeyse routingMode: tunnel yapın.
routingMode: native
ipv4NativeRoutingCIDR: "${CLUSTER_POD_CIDR}"
autoDirectNodeRoutes: true

ipv4:
  enabled: true
ipv6:
  enabled: false

# --- Ağ politikası -----------------------------------------------------------
# "default" = yalnızca bir politika tarafından seçilen endpoint'lerde zorlama.
# Cluster geneli default-deny'yi burada DEĞİL, ccnp-00-default-deny.yaml ile
# yapıyoruz — böylece açılıp kapanabilir ve muafiyetler açıkça görünür.
policyEnforcementMode: "default"

# L7 (HTTP/DNS) politika için gerekli; Gateway API de buna bağımlı.
l7Proxy: true

# --- Gateway API -------------------------------------------------------------
# CRD'ler Cilium'dan ÖNCE kurulmuş olmalı (script sırayı garanti eder).
gatewayAPI:
  enabled: true

# Cilium'un kendi L2 duyurusu KAPALI — bu işi MetalLB yapıyor.
# İkisi aynı anda açık olursa ARP çakışması olur.
l2announcements:
  enabled: false
bgpControlPlane:
  enabled: false

# Ingress controller kapalı; kuzey-güney trafiği Gateway API üzerinden.
ingressController:
  enabled: false

# --- Hubble (gözlemlenebilirlik) --------------------------------------------
# ADR-0001 Karar 2.2 #3: "servisim X'e ulaşamıyor" desteğinin maliyetini düşürür.
hubble:
  enabled: true
  metrics:
    # Faz 9 eklentisi: drop/flow/tcp'ye de `labelsContext` ile
    # source_namespace/destination_namespace eklendi — bunlar OLMADAN
    # "tenant bazlı ağ trafiği" dashboard'u (control-plane/observability/
    # dashboards/hubble-tenant-traffic.json) namespace'e göre FİLTRELEME
    # YAPAMAZDI. httpV2'nin zaten sahip olduğu context'in bir alt kümesi.
    enabled:
      - "dns:query;ignoreAAAA;labelsContext=source_namespace,destination_namespace"
      - "drop:labelsContext=source_namespace,destination_namespace"
      - "tcp:labelsContext=source_namespace,destination_namespace"
      - "flow:labelsContext=source_namespace,destination_namespace"
      - port-distribution
      - icmp
      - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction"
    # Faz 4/9: kube-prometheus-stack kuruldu → açıldı (bkz.
    # control-plane/observability/). ServiceMonitor'ın `release` etiketi
    # kube-prometheus-stack'in kendi Prometheus seçicisiyle EŞLEŞMELİDİR
    # (values.yaml'daki serviceMonitorSelector.matchLabels.release).
    serviceMonitor:
      enabled: true
  relay:
    enabled: true
    rollOutPods: true
  ui:
    enabled: true
    rollOutPods: true
    # Hubble UI'a erişim Faz 3'e kadar port-forward ile.
    # Faz 3'te Keycloak OIDC + Gateway API arkasına alınacak.
    ingress:
      enabled: false

# --- İşletim -----------------------------------------------------------------
operator:
  replicas: 2          # 3 node'luk test topolojisi için 2 yeterli (HA + tek node kaybına dayanır)
  rollOutPods: true
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true    # Faz 4/9: kube-prometheus-stack kuruldu

prometheus:
  enabled: true
  serviceMonitor:
    enabled: true      # Faz 4/9: kube-prometheus-stack kuruldu

# Node başına bant genişliği yönetimi ve sağlık kontrolü
bandwidthManager:
  enabled: true
  bbr: false           # bbr, kernel >= 5.18 ister; node imajı standartlaşınca açılabilir

healthChecking: true

# Cilium yükseltmelerinde pod kesintisini sınırla
rollOutCiliumPods: true

# Kaynak istekleri — 3 node'luk test topolojisi
resources:
  requests:
    cpu: 100m
    memory: 512Mi
  limits:
    cpu: 200m
    memory: 1Gi
