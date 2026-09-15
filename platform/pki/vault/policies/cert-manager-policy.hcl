# =============================================================================
# cert-manager Vault policy
#
# cert-manager, ÜÇ ortam Intermediate CA'sının hepsinde imzalama (sign)
# yapabilir — hangi ClusterIssuer'ın hangi ortama gittiği Kubernetes RBAC +
# Kyverno tarafından kısıtlanır (Vault tarafında tek bir güvenilir platform
# bileşeni olarak modellendi). Root CA'ya HİÇ erişimi yok.
# =============================================================================

# --- dev ---
path "pki-int-dev/sign/platform-dev" {
  capabilities = ["create", "update"]
}
path "pki-int-dev/issue/platform-dev" {
  capabilities = ["create", "update"]
}

# --- staging ---
path "pki-int-staging/sign/platform-staging" {
  capabilities = ["create", "update"]
}
path "pki-int-staging/issue/platform-staging" {
  capabilities = ["create", "update"]
}

# --- prod ---
path "pki-int-prod/sign/platform-prod" {
  capabilities = ["create", "update"]
}
path "pki-int-prod/issue/platform-prod" {
  capabilities = ["create", "update"]
}

# --- Faz 6 eklentisi: tenant başına PKI rolleri --------------------------
# XTenant composition'ı her tenant için pki-int-<env>/roles/tenant-<teamName>
# rolünü (allowed_domains = tenant-<teamName>.svc.cluster.local, bkz.
# compositions/tenant/function.k) provider-terraform ile üretiyor. Bu rolleri
# imzalamak da yine cert-manager'ın (namespaced Issuer üzerinden) işi —
# bu yüzden glob path'lerle GENİŞLETİLDİ. Glob (`*` sonek), yalnızca rol
# ADINI genişletir; her rolün KENDİ allowed_domains'i (Vault PKI role
# seviyesinde) hangi domain'in imzalanabileceğini zaten kısıtlar — bu path'ler
# cert-manager'a "hangi ROL'leri çağırabilir" der, "hangi DOMAIN'i alabilir"
# demez (o kısıtlama PKI role'ün kendisinde).
path "pki-int-dev/sign/tenant-*" {
  capabilities = ["create", "update"]
}
path "pki-int-dev/issue/tenant-*" {
  capabilities = ["create", "update"]
}
path "pki-int-staging/sign/tenant-*" {
  capabilities = ["create", "update"]
}
path "pki-int-staging/issue/tenant-*" {
  capabilities = ["create", "update"]
}
path "pki-int-prod/sign/tenant-*" {
  capabilities = ["create", "update"]
}
path "pki-int-prod/issue/tenant-*" {
  capabilities = ["create", "update"]
}

# CA zincirini okuyabilmeli (cert-manager istemcisi bazen bunu ister; ayrıca
# 03-pki.sh'in doğrulama adımı da bu path'leri kullanır — cert-manager'ın
# kendi token'ıyla değil, ayrı bir okuma-only erişimle).
path "pki-int-dev/cert/ca" {
  capabilities = ["read"]
}
path "pki-int-staging/cert/ca" {
  capabilities = ["read"]
}
path "pki-int-prod/cert/ca" {
  capabilities = ["read"]
}

# Root CA — KESİNLİKLE YOK. Eksik bir path = erişim reddi (Vault "deny by
# default"). Bunu ayrıca bir "deny" bloğuyla tekrar etmiyoruz çünkü zaten
# hiçbir path tanımlı değil.
