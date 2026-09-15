# =============================================================================
# ESO (External Secrets Operator) Vault policy — Faz 7 eklentisi (PostgreSQL)
#
# XPostgreSQLInstance composition'ı, CNPG'nin ürettiği bağlantı secret'ını
# Vault'a PUSH edip (PushSecret) sonra tenant'ın uygulama-yüzü Secret'ı
# olarak GERİ ÇEKİYOR (ExternalSecret) — bkz. compositions/postgresql/
# function.k §7. ESO'nun TEK, paylaşımlı controller kimliği (Faz 2/3) bu
# policy'yi kullanır; tüm tenant'lar için ORTAK ama yalnızca
# `tenants/<isim>/...` önekiyle SINIRLI (platformun başka hiçbir path'ine
# erişemez — örn. pki-root, pki-int-*/roles gibi yönetimsel yollara YOK).
# =============================================================================

path "kv/data/tenants/*" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/tenants/*" {
  capabilities = ["read", "list"]
}
