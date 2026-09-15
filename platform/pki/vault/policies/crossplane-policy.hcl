# =============================================================================
# Crossplane provider'ları için Vault policy — HAZIR AMA HENÜZ TÜKETİLMİYOR
#
# ADR-0001 Karar 2.3: Vault yalnızca gerçek bir ihtiyaç doğduğunda tüketilir,
# "belki lazım olur" diye önden geniş yetki verilmez. Bu policy bilinçli
# olarak MİNİMAL: yalnızca gelecekte platform-genelinde salt-okunur bir KV
# yoluna (henüz var olmayan) erişim tanımlar. Crossplane provider-kubernetes/
# provider-helm'in KENDİ İŞLEVİ (küme içi kaynak yönetimi) zaten Kubernetes
# InjectedIdentity ile çalışıyor (Faz 2) — bu policy Vault'a auth olabilmeleri
# için SADECE hazırlıktır, bugün hiçbir composition bunu kullanmıyor.
# =============================================================================

path "kv/data/platform/crossplane/*" {
  capabilities = ["read"]
}

# NOT: `kv/` mount'u BU FAZDA henüz enable EDİLMEDİ (görev kapsamı yalnızca
# PKI + Kubernetes auth). Bu path şu an karşılıksız/inert — KV v2 mount'u
# gerçek bir ihtiyaç doğduğunda (örn. CNPG dinamik kimlik bilgileri) ayrı
# bir PR ile enable edilecek.
