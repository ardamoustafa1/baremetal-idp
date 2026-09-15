# =============================================================================
# XPostgreSQLInstance composition mantığı — function-kcl pipeline adımı
# ADR-0001 Karar 2.4.
#
# BU DOSYA CANONICAL KAYNAKTIR. `composition.yaml`'daki pipeline adımının
# `input.spec.source` alanı bu dosyanın İÇERİĞİYLE BİREBİR AYNI OLMALIDIR —
# bkz. compositions/tenant/function.k'deki AYNI desen ve
# tests/verify-sync.sh (drift kontrolü).
#
# TEKNİK BORÇ (2. kez, bkz. PLATFORM_CONTEXT.md #16): naming/label mantığı
# yine `compositions/tenant/function.k` ile KOPYA — paylaşımlı bir
# `compositions/kcl/` modülüne refactor Faz 6.5'te YAPILMADI (bu görevin
# kapsamı dışında bırakıldı, ikinci kez ertelendi — borç artık İKİ
# composition'ı kapsıyor).
#
# Yerel test (cluster'sız, saf KCL):
#   kclvm_cli run function.k -D params='{"oxr": {...}}'
# =============================================================================

oxr = option("params").oxr
spec = oxr.spec
name = oxr.metadata.name

size             = spec.size
version          = spec.version
highAvailability = spec.highAvailability
tenantRef        = spec.tenantRef

# --- Tier tanımları — TEK doğruluk kaynağı --------------------------------
# retentionDays: görev metninin verdiği tier bazlı PITR saklama (7/14/30 gün).
_tiers = {
    small = {
        replicas = 1
        cpu = "2"
        memory = "4Gi"
        storage = "20Gi"
        retentionDays = 7
    }
    medium = {
        replicas = 2
        cpu = "4"
        memory = "8Gi"
        storage = "100Gi"
        retentionDays = 14
    }
    large = {
        replicas = 3
        cpu = "8"
        memory = "16Gi"
        storage = "500Gi"
        retentionDays = 30
    }
}
tier = _tiers[size]

# --- highAvailability=true + tek replika YASAK (KCL doğrulaması) ----------
# XRD'nin CEL kuralı (x-kubernetes-validations) BUNU zaten admission
# zamanında reddeder — bu, İKİNCİ bir bariyerdir (composition zamanında).
# Sabit "size == small" kontrolü DEĞİL, hesaplanan replika sayısına göre
# genel bir kontrol: tier tablosu ileride değişirse (örn. small 2 replikaya
# çıkarsa) bu kural hâlâ doğru davranır.
assert not (highAvailability and tier.replicas < 2), \
    "highAvailability=true icin minimum 2 replika gerekir (size=${size} -> ${tier.replicas} replika). size=medium veya size=large secin."

# --- PostgreSQL sürüm → CNPG imaj etiketi ---------------------------------
# NOT: Bu eşleme, versions.env'deki diğer sürüm pinleri gibi PERİYODİK
# DOĞRULANMALIDIR (patch sürümleri zamanla eskir). Kaynak:
# https://github.com/cloudnative-pg/postgres-containers/pkgs/container/postgresql
_pgImageTags = {
    "14" = "14.15"
    "15" = "15.10"
    "16" = "16.6"
    "17" = "17.2"
}
pgImage = "ghcr.io/cloudnative-pg/postgresql:${_pgImageTags[version]}"

# --- Rook-Ceph RGW — Faz 1'in sabit object store adına KENETLENMİŞ --------
# CEPH_OBJECTSTORE_NAME=platform-store (platform/underlay/.env.example).
# KCL'in shell ortam değişkenlerine erişimi YOK; bu değer bilinçli olarak
# SABİTLENDİ. Faz 1'de bu ad değişirse BU DOSYA DA güncellenmelidir
# (bkz. PLATFORM_CONTEXT.md teknik borcu).
_rgwEndpoint = "http://rook-ceph-rgw-platform-store.rook-ceph.svc.cluster.local:80"

# --- Etiketler (conventions.md §3.1 ile hizalı, tenant etiketleri Namespace
# seviyesinde zaten var — burada yalnızca kaynak-özel bilgi ekleniyor) ------
labels = {
    "platform.internal/managed-by" = "crossplane"
    "platform.internal/tenant" = tenantRef
    "platform.internal/component" = "postgresql"
    "cnpg.io/cluster" = name
}

_resAnno = lambda n: str -> {str:str} {
    {"krm.kcl.dev/composition-resource-name" = n}
}

# =============================================================================
# 1. Yedekleme bucket'ı (Rook-Ceph ObjectBucketClaim) — CNPG Barman hedefi
# =============================================================================
bucketName = "${tenantRef}-${name}-backup"

backupBucket = {
    apiVersion = "objectbucket.io/v1alpha1"
    kind = "ObjectBucketClaim"
    metadata = {
        name = "${name}-backup"
        namespace = tenantRef
        annotations = _resAnno("backup-bucket")
        labels = labels
    }
    spec = {
        bucketName = bucketName
        storageClassName = "ceph-bucket"
    }
}

# =============================================================================
# 2. cert-manager Certificate — tenant'ın KENDİ Issuer'ından (Faz 6)
#
# CNPG'nin Service adlandırma kalıbı: <cluster>-rw / -ro / -r.
# Vault PKI rolü (Faz 6b) yalnızca *.{tenantRef}.svc.cluster.local'a izin
# veriyor — bu isimler o kalıba TAM UYUYOR.
# =============================================================================
certificate = {
    apiVersion = "cert-manager.io/v1"
    kind = "Certificate"
    metadata = {
        name = "${name}-server-tls"
        namespace = tenantRef
        annotations = _resAnno("certificate")
        labels = labels
    }
    spec = {
        secretName = "${name}-server-tls"
        commonName = "${name}-rw.${tenantRef}.svc.cluster.local"
        dnsNames = [
            "${name}-rw.${tenantRef}.svc.cluster.local"
            "${name}-ro.${tenantRef}.svc.cluster.local"
            "${name}-r.${tenantRef}.svc.cluster.local"
        ]
        duration = "2160h"     # 90 gün — tenant PKI rolünün max_ttl'i ile aynı (Faz 6)
        renewBefore = "360h"   # 15 gün kala yenile
        privateKey = {algorithm = "RSA", size = 2048}
        issuerRef = {name = "tenant-issuer", kind = "Issuer", group = "cert-manager.io"}
    }
}

# =============================================================================
# 3. CloudNativePG Cluster
# =============================================================================
cluster = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind = "Cluster"
    metadata = {
        name = name
        namespace = tenantRef
        annotations = _resAnno("cluster")
        labels = labels
    }
    spec = {
        instances = tier.replicas
        imageName = pgImage

        storage = {
            size = tier.storage
            storageClass = "ceph-block"
        }

        resources = {
            requests = {cpu = tier.cpu, memory = tier.memory}
            limits = {cpu = tier.cpu, memory = tier.memory}
        }

        # cert-manager'ın ürettiği Secret, hem sunucu sertifikası hem CA
        # bundle'ı içerir (Vault issuer zinciri) — CNPG ikisi için de aynı
        # Secret'ı referans alabilir.
        certificates = {
            serverTLSSecret = "${name}-server-tls"
            serverCASecret = "${name}-server-tls"
        }

        affinity = {
            enablePodAntiAffinity = True
            topologyKey = "kubernetes.io/hostname"
        }

        monitoring = {
            # Kendi ServiceMonitor'ümüzü üretiyoruz (aşağıda) — operatörün
            # varsayılan PodMonitor'ü KAPALI, tek bir izleme yolu olsun.
            enablePodMonitor = False
        }

        backup = {
            barmanObjectStore = {
                destinationPath = "s3://${bucketName}/"
                endpointURL = _rgwEndpoint
                s3Credentials = {
                    accessKeyId = {name = "${name}-backup", key = "AWS_ACCESS_KEY_ID"}
                    secretAccessKey = {name = "${name}-backup", key = "AWS_SECRET_ACCESS_KEY"}
                }
                wal = {compression = "gzip"}
                data = {compression = "gzip"}
            }
            retentionPolicy = "${tier.retentionDays}d"
        }
    }
}

# =============================================================================
# 4. Günlük yedek zamanlaması — CNPG'nin NATIVE ScheduledBackup mekanizması
#    (CronJob DEĞİL — Barman entegrasyonuyla birebir uyumlu, PITR'ı bozmaz)
# =============================================================================
scheduledBackup = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind = "ScheduledBackup"
    metadata = {
        name = "${name}-daily-backup"
        namespace = tenantRef
        annotations = _resAnno("scheduled-backup")
        labels = labels
    }
    spec = {
        # Her gün 02:00 UTC — tenant'lar arası yük dağılımı için isim hash'ine
        # göre dakika kaydırılabilir; şimdilik sabit (basitlik tercih edildi).
        schedule = "0 0 2 * * *"
        backupOwnerReference = "self"
        cluster = {name = name}
    }
}

# =============================================================================
# 5. CiliumNetworkPolicy — Tenant'ın default-deny'sinin ÜSTÜNE EKLENEN,
#    yalnızca 5432 portuna aynı-tenant erişimi izni (additive, bozmaz)
# =============================================================================
networkPolicy = {
    apiVersion = "cilium.io/v2"
    kind = "CiliumNetworkPolicy"
    metadata = {
        name = "${name}-postgres-access"
        namespace = tenantRef
        annotations = _resAnno("networkpolicy")
        labels = labels
    }
    spec = {
        endpointSelector = {matchLabels = {"cnpg.io/cluster" = name}}
        ingress = [
            {
                fromEndpoints = [
                    {matchLabels = {"k8s:io.kubernetes.pod.namespace" = tenantRef}}
                ]
                toPorts = [
                    {ports = [{port = "5432", protocol = "TCP"}]}
                ]
            }
        ]
    }
}

# =============================================================================
# 6. ServiceMonitor — Faz 4'e kadar (Prometheus Operator CRD'si) inert kalır
# =============================================================================
serviceMonitor = {
    apiVersion = "monitoring.coreos.com/v1"
    kind = "ServiceMonitor"
    metadata = {
        name = "${name}-postgres-metrics"
        namespace = tenantRef
        annotations = _resAnno("servicemonitor")
        labels = labels
    }
    spec = {
        selector = {matchLabels = {"cnpg.io/cluster" = name}}
        endpoints = [
            {port = "metrics", path = "/metrics", interval = "30s"}
        ]
    }
}

# =============================================================================
# 7. ESO: SecretStore (Vault, KV v2) + PushSecret + ExternalSecret
#
# CNPG, "<cluster>-app" adında bir Secret'ı OTOMATİK üretir (host/port/user/
# password/dbname). Bu zaten tenant namespace'inde — teoride doğrudan
# kullanılabilir. Görev AÇIKÇA bir ExternalSecret istediği için (muhtemelen
# tüm uygulama secret'larının TEK bir mekanizmadan — Vault üzerinden —
# geçmesini standartlaştırmak amacıyla, ADR-0001 Karar 2.3), CNPG'nin
# ürettiği Secret Vault'a PUSH edilir, sonra uygulamanın kullanacağı
# `<name>-connection` Secret'ı olarak GERİ ÇEKİLİR. Bu round-trip bilinçlidir
# — bkz. README "Neden ExternalSecret, CNPG'nin Secret'ı zaten yeterliyken?"
# =============================================================================
vaultKvPath = "tenants/${tenantRef}/postgresql/${name}"

secretStore = {
    apiVersion = "external-secrets.io/v1beta1"
    kind = "SecretStore"
    metadata = {
        name = "${name}-vault-backend"
        namespace = tenantRef
        annotations = _resAnno("secretstore")
        labels = labels
    }
    spec = {
        provider = {
            vault = {
                server = "http://vault-active.vault.svc.cluster.local:8200"
                path = "kv"
                version = "v2"
                auth = {
                    kubernetes = {
                        mountPath = "kubernetes"
                        # ÖNCEDEN: tüm tenant'lar arasında PAYLAŞILAN
                        # "eso-tenant-secrets" rolü (açık karar #16). Şimdi
                        # HER tenant'ın (compositions/tenant/function.k'nin
                        # provider-terraform Workspace'inde ürettiği) KENDİ
                        # Vault k8s-auth role'ü + KENDİ ServiceAccount'u
                        # kullanılıyor — path-prefix izolasyonuna EK olarak
                        # artık KİMLİK izolasyonu da var (tenant A'nın ESO
                        # kimliği, tenant B'nin kv path'ini Vault policy
                        # SEVİYESİNDE OKUYAMAZ, yalnızca uygulama mantığına
                        # güvenilmiyor).
                        role = "eso-tenant-${tenantRef}"
                        serviceAccountRef = {
                            name = "eso-tenant-secrets"
                            namespace = tenantRef
                        }
                    }
                }
            }
        }
    }
}

pushSecret = {
    apiVersion = "external-secrets.io/v1alpha1"
    kind = "PushSecret"
    metadata = {
        name = "${name}-push-to-vault"
        namespace = tenantRef
        annotations = _resAnno("pushsecret")
        labels = labels
    }
    spec = {
        refreshInterval = "1h"
        secretStoreRefs = [
            {name = "${name}-vault-backend", kind = "SecretStore"}
        ]
        selector = {
            secret = {name = "${name}-app"}   # CNPG'nin native ürettiği secret
        }
        data = [
            # secretKey/property BİLİNÇLİ OLARAK BOŞ: tüm secret'ı TEK bir
            # blob olarak remoteKey altına gönderir (ESO PushSecret idiomu).
            {match = {remoteRef = {remoteKey = vaultKvPath}}}
        ]
    }
}

externalSecret = {
    apiVersion = "external-secrets.io/v1beta1"
    kind = "ExternalSecret"
    metadata = {
        name = "${name}-connection"
        namespace = tenantRef
        annotations = _resAnno("externalsecret")
        labels = labels
    }
    spec = {
        refreshInterval = "1h"
        secretStoreRef = {name = "${name}-vault-backend", kind = "SecretStore"}
        target = {
            name = "${name}-connection"
            creationPolicy = "Owner"
        }
        data = [
            {secretKey = "host", remoteRef = {key = vaultKvPath, property = "host"}}
            {secretKey = "port", remoteRef = {key = vaultKvPath, property = "port"}}
            {secretKey = "username", remoteRef = {key = vaultKvPath, property = "username"}}
            {secretKey = "password", remoteRef = {key = vaultKvPath, property = "password"}}
            {secretKey = "dbname", remoteRef = {key = vaultKvPath, property = "dbname"}}
        ]
    }
}

# =============================================================================
# 8. PodDisruptionBudget — yalnızca highAvailability=true iken
#
# NOT: CNPG KENDİ PDB'lerini de otomatik yönetir (birincil + topluluk).
# Bu EK PDB, görev tanımının açıkça istediği, adı farklı, tenant'ın
# "en az 1 replika her zaman ayakta" beklentisini genel olarak ifade eden
# bir kaynaktır — CNPG'nin kendi PDB'leriyle ÇAKIŞMAZ (farklı isim/selector
# birleşimi kullanır).
# =============================================================================
_pdb = {
    apiVersion = "policy/v1"
    kind = "PodDisruptionBudget"
    metadata = {
        name = "${name}-custom-pdb"
        namespace = tenantRef
        annotations = _resAnno("poddisruptionbudget")
        labels = labels
    }
    spec = {
        minAvailable = 1
        selector = {matchLabels = {"cnpg.io/cluster" = name}}
    }
}
_pdbItems = [_pdb] if highAvailability else []

# =============================================================================
# 9. Backstage catalog-info — otomatik katalog kaydı (Faz 8)
# Aynı mekanizma: compositions/tenant/function.k §8'deki gerekçenin AYNISI.
# =============================================================================
_catalogInfoYaml = """
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: postgres-${name}
  title: "PostgreSQL: ${name}"
  description: "CloudNativePG instance — size=${size}, HA=${highAvailability}"
  annotations:
    backstage.io/kubernetes-namespace: ${tenantRef}
  tags:
    - postgresql
    - database
spec:
  type: database
  lifecycle: production
  # NOT: postgresql/function.k yalnızca tenantRef'i (namespace adı) bilir,
  # takımın Keycloak/Backstage Group adını BİLMEZ (bkz. README "tenantRef ne
  # anlama geliyor") — bu yüzden owner burada bilinçli olarak platform-team.
  # Gerçek sahiplik, bağımlı olduğu tenant Component'inin (aşağıdaki
  # dependsOn) owner'ından okunmalıdır.
  owner: platform-team
  system: internal-developer-platform
  # tenantRef ("tenant-<teamName>-<environment>") conventions §2.1 gereği
  # tenant Component'inin KENDİ adıyla ("tenant-<teamName>-<environment>",
  # bkz. compositions/tenant/function.k §8) BİREBİR AYNI string'tir —
  # bu yüzden doğrudan referans verilebilir.
  dependsOn:
    - component:default/${tenantRef}
"""

catalogInfoConfigMap = {
    apiVersion = "v1"
    kind = "ConfigMap"
    metadata = {
        name = "${name}-catalog-info"
        namespace = tenantRef
        annotations = _resAnno("catalog-info")
        labels = {**labels, "backstage.io/catalog-info" = "true"}
    }
    data = {"catalog-info.yaml" = _catalogInfoYaml}
}

items = [
    backupBucket
    certificate
    cluster
    scheduledBackup
    networkPolicy
    serviceMonitor
    secretStore
    pushSecret
    externalSecret
    catalogInfoConfigMap
] + _pdbItems
