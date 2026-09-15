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

# DÜZELTME (Faz 12j, code review #8 — güvenlik sınırı): bu policy ÖNCEDEN
# (Faz 6 eklentisi) `pki-int-<env>/sign/tenant-*` GLOB'una sahipti — bu
# policy'yi kullanan Vault auth role'ü (auth/kubernetes/role/cert-manager)
# TÜM tenant namespace'lerine `bound_service_account_namespace_selector`
# ile BAĞLIYDI, yani HERHANGİ bir tenant'ın cert-manager SA'sı bu policy
# ÜZERİNDEN Vault API'sine DOĞRUDAN çağrı yapıp BAŞKA bir tenant'ın
# `tenant-*` PKI rolünü imzalayabilirdi (cert-manager'ın normal Issuer/
# Certificate CRD akışı bunu ENGELLEMEZ — bu, o akışın TAMAMEN DIŞINDA,
# ham bir Vault API çağrısıdır). Glob KALDIRILDI — her tenant artık KENDİ
# `cert-manager-tenant-<nsName>` policy'sini kullanır (yalnızca KENDİ
# `tenant-<nsName>` rolünü imzalayabilir; bkz. compositions/tenant/
# function.k'nin `_vaultBootstrapScript`'i, `tenant-<nsName>`/`eso-tenant-
# <nsName>` İLE AYNI desende üretir). BU policy artık YALNIZCA platform-
# genelinde ClusterIssuer'lar (platform-dev/staging/prod) İÇİN kullanılır.

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
