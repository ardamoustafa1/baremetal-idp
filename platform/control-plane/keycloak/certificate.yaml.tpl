# =============================================================================
# Keycloak TLS sertifikası — Vault PKI (Faz 3) üzerinden, cert-manager ile.
#
# ÖN KOŞUL: Faz 3 (03-pki.sh) tamamlanmış olmalı — `vault-issuer-dev`
# ClusterIssuer'ı hazır olmadan bu Certificate PENDING'de kalır.
#
# NEDEN AYRI BİR DOSYA (01-underlay.sh'in install_keycloak() fonksiyonuna
# GÖMÜLMEDİ): Keycloak Faz 1'de kurulur ama Vault PKI ancak Faz 3'te hazır
# olur — Vault'un kendi self-TLS runbook'u (docs/runbooks/vault-self-tls.md)
# ile AYNI desen: bu, bootstrap akışına otomatik BAĞLANMAZ, Faz 3
# tamamlandıktan SONRA elle (veya 03-pki.sh'e eklenecek ayrı bir adımla)
# uygulanır. `values.yaml.tpl`'deki `tls.*` alanları BU Secret'ı bekler
# (`existingSecret: keycloak-tls`, `usePem: true` — cert-manager'ın ürettiği
# `tls.crt`/`tls.key` anahtarlarıyla BİREBİR uyumlu).
# =============================================================================
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: keycloak
  labels:
    platform.internal/layer: control-plane
spec:
  secretName: keycloak-tls
  commonName: "${KEYCLOAK_HOSTNAME}"
  dnsNames:
    - "${KEYCLOAK_HOSTNAME}"
  issuerRef:
    name: vault-issuer-dev
    kind: ClusterIssuer
