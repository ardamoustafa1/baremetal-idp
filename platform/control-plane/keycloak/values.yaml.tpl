# =============================================================================
# Keycloak — OIDC kimlik sağlayıcı
# ADR-0001 L4. Kurulum sırasında İLK gelen control-plane bileşeni:
# Harbor / ArgoCD / Grafana / Backstage / Vault hepsi buna bağlanacak.
#
# Faz 1 kapsamı: realm + admin. Client'lar ilgili bileşen kurulduğunda,
# o bileşenin fazında eklenir.
#
# BU DOSYADA PAROLA YOKTUR.
# =============================================================================

# --- Yönetici -------------------------------------------------------------
auth:
  adminUser: "${KEYCLOAK_ADMIN_USER}"
  # Parola script tarafından bu secret'a yazılır (.env'den)
  existingSecret: keycloak-admin-password
  passwordSecretKey: admin-password

# --- Üretim modu ----------------------------------------------------------
# DÜZELTME (Faz 12c, GERÇEK bir kind cluster'ında uçtan uca test edildi):
# `production: true` + `tls.*` etkinleştirildi — Vault PKI (Faz 3) +
# cert-manager'ın ürettiği `keycloak-tls` Secret'ı (bkz. resources/
# certificate.yaml.tpl) kullanılıyor. ÖNEMLİ SIRALAMA NOTU: bu, Keycloak'un
# Faz 1'de (bu dosya) kurulduğu ama Vault PKI'nin ancak Faz 3'te hazır
# olduğu GERÇEK bir çapraz-faz bağımlılığı yaratır — `docs/runbooks/
# k8s-api-server-oidc.md`'nin §0'ında ZATEN doğru şekilde işaretlenmişti.
# Pratik sonuç: ilk kurulumda (Faz 1) bu TLS ayarları `enabled: false`
# bırakılmalı, Faz 3 (Vault PKI + cert-manager) tamamlandıktan SONRA bu
# dosya güncellenip Keycloak `helm upgrade` ile YENİDEN uygulanmalıdır
# (Vault'un kendi self-TLS'i gibi — bkz. docs/runbooks/vault-self-tls.md —
# BİLİNÇLİ olarak otomatik bootstrap akışına ELLE tetiklenen bir adım
# olarak bırakıldı).
production: true
proxy: edge

# Hostname: Keycloak'un ürettiği OIDC issuer URL'inin doğru olması için ZORUNLU.
# Yanlışsa, token'ları doğrulayan her istemci sessizce reddeder.
extraEnvVars:
  - name: KC_HOSTNAME
    value: "${KEYCLOAK_HOSTNAME}"
  - name: KC_HOSTNAME_STRICT
    value: "false"
  - name: KC_HTTP_ENABLED
    value: "true"
  # Faz 1'de realm'i import ile yaratıyoruz (aşağıdaki initdb/realm ConfigMap)
  - name: KEYCLOAK_EXTRA_ARGS
    value: "--import-realm"

# --- TLS (Faz 3+, Vault PKI hazır olunca — yukarıdaki production notuna
# bakın) -----------------------------------------------------------------
tls:
  enabled: true
  existingSecret: keycloak-tls
  usePem: true

extraVolumes:
  - name: realm-import
    configMap:
      name: keycloak-realm-import
extraVolumeMounts:
  - name: realm-import
    mountPath: /opt/bitnami/keycloak/data/import
    readOnly: true

# --- Erişim ---------------------------------------------------------------
service:
  type: LoadBalancer             # MetalLB havuzdan IP atar; sabit IP yok
  ports:
    http: 80
    https: 443

ingress:
  enabled: false                 # Faz 3'te Gateway API + TLS ile

# --- Veritabanı -----------------------------------------------------------
postgresql:
  enabled: true
  # TEKNİK BORÇ: Faz 4'te CloudNativePG'ye taşınacak (PLATFORM_CONTEXT #2).
  auth:
    existingSecret: keycloak-db-password
    secretKeys:
      adminPasswordKey: postgres-password
      userPasswordKey: password
  primary:
    persistence:
      enabled: true
      storageClass: "ceph-block"
      size: 10Gi
    resources:
      requests: {cpu: 200m, memory: 512Mi}
      limits:   {cpu: 400m, memory: 1Gi}

# --- Kaynaklar ------------------------------------------------------------
replicaCount: 1                  # Faz 4'te 2'ye çıkarılacak (HA)
resources:
  requests: {cpu: 300m, memory: 768Mi}
  limits:   {cpu: 600m, memory: 1536Mi}

readinessProbe:
  enabled: true
  initialDelaySeconds: 60
livenessProbe:
  enabled: true
  initialDelaySeconds: 120       # Keycloak ilk açılışta şema migrasyonu yapar

metrics:
  enabled: true
  serviceMonitor:
    enabled: false               # Faz 4

# --- İmaj kayıt defteri ---------------------------------------------------
# Bitnami imaj dağıtım politikası değişti (bkz. underlay/README.md riskler).
# İç mirror kullanıyorsanız .env'de KEYCLOAK_IMAGE_REGISTRY set edin.
global:
  imageRegistry: "${KEYCLOAK_IMAGE_REGISTRY}"
