# =============================================================================
# Keycloak TLS overlay — Faz 3 (Vault PKI + cert-manager) TAMAMLANDIKTAN
# SONRA `values.yaml.tpl`'in ÜZERİNE eklenir (Vault'un KENDİ self-TLS
# deseniyle BİREBİR AYNI, bkz. pki/vault/values-tls.yaml).
#
# `keycloak-tls` Secret'ı `certificate.yaml.tpl`'den (cert-manager
# Certificate → vault-issuer-dev ClusterIssuer) üretilir — bu overlay'in
# KENDİSİ bu Secret'ı OLUŞTURMAZ, yalnızca VAR OLDUĞUNU VARSAYAR.
# `03-pki.sh`'in `enable_keycloak_tls()` fonksiyonu: (1) Certificate'ı
# render edip uygular, (2) Secret'ın hazır olmasını bekler, (3) BU overlay
# İLE `helm upgrade` yapar. Keycloak'ın Bitnami chart'ı (24.4.7)
# `updateStrategy.type: RollingUpdate` kullanır (Vault'un `OnDelete`
# İSTİSNASININ AKSİNE, `helm show values bitnami/keycloak --version
# 24.4.7` ile CANLI doğrulandı) — yani bu overlay eklenip `helm upgrade`
# çalıştırıldığında pod'lar KENDİLİĞİNDEN yeniden başlar, Vault'taki gibi
# elle sıralı pod silme GEREKMEZ.
# =============================================================================
tls:
  enabled: true
  existingSecret: keycloak-tls
  usePem: true
