# =============================================================================
# Vault-backed ClusterIssuer'lar — ortam başına bir tane
#
# Kimlik doğrulama: Kubernetes auth + serviceAccountRef (cert-manager 1.13+).
# STATİK BİR TOKEN SECRET'I YOK — cert-manager kendi ServiceAccount'ının
# kısa ömürlü, otomatik yenilenen bir projected token'ını (TokenRequest API)
# kullanır. Eski `auth.kubernetes.secretRef` (uzun ömürlü statik SA token
# Secret'ı) BİLİNÇLİ OLARAK tercih EDİLMEDİ.
#
# server: Vault'un HA "active" Service'i — yalnızca lider node'a yazar.
#
# DÜZELTME (Faz 12g, code review #8): server ÖNCEDEN `http://` idi (Vault'un
# listener'ı tls_disable=1 iken tek seçenek buydu). 03-pki.sh'in
# `enable_vault_tls()` adımı artık Vault'un listener'ını KENDİ PKI'sinden
# (pki-int-dev) imzalı bir sertifikayla HTTPS'e geçiriyor — bu dosya artık
# `.tpl` (envsubst ile render edilir, bkz. install_cert_manager()) ve
# `caBundle`, o adımın ${PKI_DIR}/trust-bundles/vault-ca-chain.pem'e
# yazdığı intermediate+root zincirinin base64'ü ile doldurulur. caBundle
# olmadan cert-manager, Vault'un (kamu CA'sı tarafından imzalanmamış)
# sunucu sertifikasını GÜVENMEZ ve her Issuer "x509: certificate signed by
# unknown authority" ile Ready=False kalırdı.
# =============================================================================
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer-dev
  labels:
    platform.internal/layer: pki
spec:
  vault:
    server: https://vault-active.vault.svc.cluster.local:8200
    caBundle: ${VAULT_CA_BUNDLE_B64}
    path: pki-int-dev/sign/platform-dev
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer-staging
  labels:
    platform.internal/layer: pki
spec:
  vault:
    server: https://vault-active.vault.svc.cluster.local:8200
    caBundle: ${VAULT_CA_BUNDLE_B64}
    path: pki-int-staging/sign/platform-staging
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer-prod
  labels:
    platform.internal/layer: pki
spec:
  vault:
    server: https://vault-active.vault.svc.cluster.local:8200
    caBundle: ${VAULT_CA_BUNDLE_B64}
    path: pki-int-prod/sign/platform-prod
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
