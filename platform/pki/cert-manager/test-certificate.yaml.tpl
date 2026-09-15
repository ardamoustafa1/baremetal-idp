# =============================================================================
# Test sertifikası — 03-pki.sh'in verify_certificate() adımı tarafından
# uygulanıp doğrulanır, sonra silinir. Kalıcı bir kaynak DEĞİLDİR.
# =============================================================================
apiVersion: v1
kind: Namespace
metadata:
  name: pki-test
  labels:
    platform.internal/managed-by: pki-bootstrap
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pki-smoke-test
  namespace: pki-test
spec:
  secretName: pki-smoke-test-tls
  commonName: smoke-test.dev.${PLATFORM_BASE_DOMAIN}
  dnsNames:
    - smoke-test.dev.${PLATFORM_BASE_DOMAIN}
  duration: 24h
  renewBefore: 8h
  privateKey:
    algorithm: RSA
    size: 2048
  issuerRef:
    name: vault-issuer-dev
    kind: ClusterIssuer
    group: cert-manager.io
