# =============================================================================
# Root CA yönetici policy — BREAK-GLASS. Normal operasyonda KİMSEYE
# atanmaz. Yalnızca docs/runbooks/vault-unseal.md'deki break-glass
# prosedürü sırasında, ikinci bir yetkilinin onayıyla geçici olarak
# bir insan/token'a bağlanır.
#
# Root CA (pki-root), Intermediate CA'ları imzaladıktan SONRA bu policy'nin
# dışına alınır (kimseye atanmaz) — "offline root" ilkesinin Vault OSS
# içindeki en yakın karşılığı. Ayrıntı: pki/vault/README.md.
# =============================================================================

path "pki-root/root/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "pki-root/root/sign-intermediate" {
  capabilities = ["create", "update"]
}
path "pki-root/cert/ca" {
  capabilities = ["read"]
}
path "sys/mounts/pki-root" {
  capabilities = ["create", "read", "update", "delete"]
}
