# =============================================================================
# CLUSTER-WIDE DEFAULT-DENY
#
# !!! BU DOSYA SON UYGULANIR VE ENABLE_DEFAULT_DENY=true GEREKTİRİR !!!
#
# Neden bayrak arkasında:
#   Bu politika uygulandığı anda, izin verilmemiş HER akış düşer. Kurulum
#   sırasında uygulanırsa Rook'un OSD hazırlığı, Harbor'un DB bağlantısı veya
#   admission webhook'ları sessizce timeout'a düşer ve arıza "ağ" gibi
#   görünmez — "kurulum takıldı" gibi görünür.
#
# Kapsam:
#   - Platform namespace'leri MUAF (${DEFAULT_DENY_EXEMPT_NAMESPACES}).
#     Bu muafiyet geçicidir: Faz 4'te her platform bileşeni kendi açık
#     politikasını alınca liste daraltılacaktır (bkz. teknik borç kaydı).
#   - Tenant namespace'leri (tenant-*) ASLA muaf değildir. Faz 6'da her tenant,
#     composition tarafından üretilen kendi allow politikalarıyla gelir.
#
# Geri alma:
#   kubectl delete ciliumclusterwidenetworkpolicy platform-default-deny
#   (Etki anında; Cilium politikayı kaldırınca endpoint'ler audit dışı kalır.)
#
# Doğrulama — politikayı açmadan ÖNCE etkisini görmek için:
#   cilium policy trace --src-k8s-pod default:test --dst-k8s-pod kube-system:...
#   hubble observe --verdict DROPPED --follow
# =============================================================================
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: platform-default-deny
  labels:
    platform.internal/managed-by: underlay-bootstrap
    platform.internal/layer: underlay
  annotations:
    platform.internal/description: >-
      Taban default-deny. Tenant'lar Faz 6'da composition tarafından üretilen
      kendi CiliumNetworkPolicy'leriyle bunu gevşetir.
    platform.internal/runbook-url: platform/underlay/cilium/README.md
spec:
  description: >-
    Muaf namespace'ler dışındaki tüm endpoint'ler için varsayılan olarak
    ingress ve egress reddedilir.
  endpointSelector:
    matchExpressions:
      - key: k8s:io.kubernetes.pod.namespace
        operator: NotIn
        values:
${DEFAULT_DENY_EXEMPT_YAML_LIST}
  # Cilium 1.14+ : kural listesi olmadan salt default-deny tanımlar.
  # Bu alan olmadan "boş politika" hiçbir şey zorlamaz — sessiz no-op olur.
  enableDefaultDeny:
    ingress: true
    egress: true
