# =============================================================================
# ESO Vault policy — PLATFORM-genelinde secret'lar (Faz 8 eklentisi)
#
# `eso-tenant-secrets`'ten (Faz 7) FARKLI bir Vault k8s-auth ROLÜ — AYNI ESO
# controller SA'sına bağlı, ama FARKLI bir path prefix'ine ({{kv/data/platform/*}}"
# scoped. Vault'ta bir ServiceAccount, farklı rollere farklı policy'lerle
# bağlanabilir — bu, tenant-scoped ve platform-scoped secret erişimini AYNI
# SA'yı paylaşırken bile birbirinden AYIRIR (bir tenant path'i asla platform
# path'ine karışmaz, ve tam tersi).
# =============================================================================

path "kv/data/platform/*" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/*" {
  capabilities = ["read", "list"]
}
