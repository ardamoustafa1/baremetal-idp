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
# `production: true` açık — bu Vault PKI'ye BAĞLI DEĞİL, TLS'DEN BAĞIMSIZ
# bir chart ayarı (KC_PROXY/health check modunu etkiler).
#
# DÜZELTME (bu turda, taze bir denetimde bulundu — KRİTİK): `tls.*` alanları
# ÖNCEDEN BU DOSYADA `enabled: true` olarak SABİTLENMİŞTİ — ama bu dosyanın
# KENDİ üstteki yorumu (ve `certificate.yaml.tpl`'in kendi başlık yorumu)
# AÇIKÇA "ilk kurulumda (Faz 1) bu TLS ayarları `enabled: false` bırakılmalı,
# Vault PKI (Faz 3) tamamlandıktan SONRA ayrı bir adımla açılmalı" diyordu —
# koddaki DEĞER bu NİYETİN TAM TERSİYDİ. Sonuç: `keycloak-tls` Secret'ını
# üretecek `certificate.yaml.tpl` HİÇBİR script tarafından uygulanmadığı
# (yalnızca yorumlarda "ayrı bir adımla uygulanacak" deniyordu, o adım hiç
# YAZILMAMIŞTI) için, sıfır bir cluster'da `install_keycloak()` var OLMAYAN
# bir Secret'ı mount etmeye çalışıp `ContainerCreating`'de asılı kalıyor,
# 15 dakika sonra `wait_for` zaman aşımına uğrayıp TÜM Faz 1'i (Harbor VE
# network policy adımı DAHİL) durduruyordu.
#
# ÇÖZÜM: Vault'un KENDİ self-TLS deseniyle (values.yaml + values-tls.yaml
# İKİ AŞAMALI overlay, bkz. pki/vault/values-tls.yaml) BİREBİR AYNI —
# `tls.*` bu dosyadan TAMAMEN ÇIKARILDI, `values-tls.yaml.tpl`'e taşındı.
# `01-underlay.sh`'in `install_keycloak()`'ı artık `keycloak-tls` Secret'ı
# VARSA `-f values-tls.yaml` overlay'ini EKLİYOR (Vault'un `install_vault()`
# fonksiyonundaki AYNI koşullu-overlay deseni); Secret'ı GERÇEKTEN üreten
# adım ise `03-pki.sh`'in YENİ `enable_keycloak_tls()` fonksiyonudur (Vault
# PKI/cert-manager hazır olduktan SONRA, Faz 3'te çalışır — TAM OLARAK
# yorumların HER ZAMAN tarif ettiği ama hiç yazılmamış akış).
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
