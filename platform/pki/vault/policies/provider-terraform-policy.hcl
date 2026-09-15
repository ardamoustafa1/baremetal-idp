# =============================================================================
# provider-terraform Vault policy — Faz 6 eklentisi
#
# XTenant composition'ı, tenant başına Vault k8s-auth role + policy + PKI
# role'ü provider-terraform (Crossplane'in escape hatch'i, ADR-0001 Karar 2.1)
# üzerinden yönetiyor (bkz. compositions/tenant/function.k). Bu Terraform
# modülünün Vault'a auth olabilmesi VE gerekli kaynakları YÖNETEBİLMESİ için
# provider-terraform'un KENDİ ServiceAccount'ının bir Vault k8s-auth rolüne
# ihtiyacı var — bu policy o rolün izin sınırıdır.
#
# KAPSAM BİLİNÇLİ OLARAK DAR: yalnızca `tenant-*` adlı kaynaklar. Platform
# genelindeki (`platform-*`) roller/policy'ler BURADAN YÖNETİLEMEZ —
# provider-terraform'un yanlışlıkla (veya bir composition hatasıyla) platform
# genelindeki PKI rollerini bozması engellenir.
# =============================================================================

path "auth/kubernetes/role/tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "sys/policies/acl/tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}

# DÜZELTME (Faz 12b, GERÇEK kind cluster'ında keşfedildi): ESO'nun tenant
# başına kimliği (compositions/tenant/function.k, "eso_tenant" kaynakları)
# "eso-tenant-<nsName>" adını kullanıyor — bu, "tenant-*" glob'una UYMUYOR
# ("eso-tenant-..." harfi harfine "tenant-" ile BAŞLAMIYOR). Bu satırlar
# olmadan provider-terraform kimliği (doğru auth olsa BİLE) "permission
# denied" alırdı — canlı bir token ile doğrulandı.
path "auth/kubernetes/role/eso-tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "sys/policies/acl/eso-tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "pki-int-dev/roles/tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "pki-int-staging/roles/tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "pki-int-prod/roles/tenant-*" {
  capabilities = ["create", "read", "update", "delete"]
}
