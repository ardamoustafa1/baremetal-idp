# =============================================================================
# Kyverno imageVerify — Harbor'dan çekilen HİÇBİR imaj, Cosign ile
# imzalanmamışsa çalıştırılamaz. Faz 10, görev madde 1.
#
# NEDEN Cosign, Notation DEĞİL: platform zaten `cosign` CLI'yi CI'da
# kullanacak (bkz. `.github/workflows/image-supply-chain.yaml`) ve
# Kyverno'nun `verifyImages` kuralı Cosign imzalarını YERLEŞİK olarak
# doğrular — Notation için ayrı bir doğrulayıcı eklenti (trust policy +
# Notation plugin) gerekir. Notation, platformun mevcut zincirine (syft/
# Trivy/Harbor hepsi Cosign ekosistemiyle uyumlu) ekstra bir bağımlılık
# katmadan bırakıldı — bu BİLİNÇLİ bir kapsam daraltmasıdır (teknik borç
# olarak PLATFORM_CONTEXT.md'de kayıtlıdır).
#
# ANAHTAR YÖNETİMİ: Bu policy, public anahtarı bir Kubernetes Secret'tan
# okur (`k8s://kyverno/cosign-image-signing-key`) — GERÇEK ANAHTAR ÇİFTİ
# `05-observability.sh` gibi bir bootstrap script'i DEĞİL, CI/CD pipeline'ının
# imza ATMA adımı (image-supply-chain.yaml) tarafından kullanılan ÖZEL
# anahtarla EŞLEŞMELİDİR — özel anahtar GitHub Actions Secret'ında durur,
# Git'e ASLA yazılmaz (bkz. o workflow'un yorumları).
#
# GERÇEK DOĞRULAMA (bu görevde yapıldı): yerel bir Docker registry (`registry:2`)
# ayağa kaldırıldı, `cosign generate-key-pair` ile GERÇEK bir anahtar çifti
# üretildi, bir imaj imzalandı diğeri imzasız bırakıldı; `kyverno apply` bu
# policy'yi GERÇEK registry'ye karşı çalıştırıp imzalı imajı KABUL, imzasız
# imajı REDDETTİ (bkz. platform/policies/tests/require-signed-images/README.md).
# =============================================================================
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
  annotations:
    policies.kyverno.io/title: Require Cosign-signed images
    policies.kyverno.io/category: Software Supply Chain
    policies.kyverno.io/severity: critical
    policies.kyverno.io/subject: Pod
    policies.kyverno.io/description: >-
      Harbor registry'sinden (${HARBOR_HOSTNAME}) çekilen hiçbir imaj,
      platformun Cosign anahtarıyla imzalanmamışsa Pod'a dönüştürülemez.
spec:
  webhookTimeoutSeconds: 30
  failurePolicy: Fail
  rules:
    - name: verify-harbor-image-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      # NOT: imageReferences sabit bir örnek domain'le (harbor.
      # apps.platform.internal) yazıldı — 05-observability.sh benzeri bir
      # bootstrap adımı bu policy'yi `envsubst` ile `${HARBOR_HOSTNAME}`
      # üzerinden render ETMELİDİR (bkz. tests/README.md "kurulum notu").
      # Kyverno ClusterPolicy'leri Helm/envsubst şablon MEKANİZMASINA sahip
      # değil — bu yüzden policies/README.md'nin "politika yaşam döngüsü"
      # kuralına uyularak, gerçek kurulumdan önce bu satırın ELLE (veya
      # bir `sed`/envsubst adımıyla) güncellenmesi GEREKTİĞİ burada
      # açıkça işaretlendi.
      #
      # DÜZELTME (Faz 12c, GERÇEK bir kind cluster'ında keşfedildi): bu
      # kural düzeyinde (match'in yanında) bir `imageReferences` alanı
      # DAHA vardı — Kyverno v1 ClusterPolicy şemasında `imageReferences`
      # YALNIZCA `verifyImages[]` altında GEÇERLİDİR, kural düzeyinde HİÇ
      # YOK. `kubectl apply` "strict decoding error: unknown field
      # spec.rules[0].imageReferences" ile KESİN olarak reddediyordu — bu
      # policy hiçbir gerçek cluster'a UYGULANMAMIŞTI. Fazladan/geçersiz
      # alan kaldırıldı.
      verifyImages:
        - imageReferences:
            - "${HARBOR_HOSTNAME}/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    secret:
                      name: cosign-image-signing-key
                      namespace: kyverno
                    # DÜZELTME (Faz 12c, GERÇEK bir kind cluster'ında GERÇEK
                    # bir admission webhook denemesiyle keşfedildi): CI'nın
                    # kendi imzalama adımı (image-supply-chain.yaml)
                    # `cosign sign --tlog-upload=false` kullanıyor — yani
                    # Rekor'a HİÇ YÜKLEME YAPMIYOR (bilinçli, private/
                    # air-gapped registry senaryosu). Bu alan olmadan
                    # Kyverno VARSAYILAN olarak Rekor tlog doğrulaması
                    # BEKLİYOR — CI'nın İMZALADIĞI HER İMAJ "no matching
                    # signatures: signature not found in transparency log"
                    # ile REDDEDİLİRDİ (canlı doğrulandı: doğru anahtarla
                    # imzalanmış bir imaj bile bu alan olmadan reddedildi,
                    # eklenince kabul edildi). Test fixture'ında
                    # (tests/require-signed-images/policy-test.yaml) bu
                    # düzeltme zaten VARDI ama gerçek şablona hiç
                    # YANSITILMAMIŞTI.
                    rekor:
                      ignoreTlog: true
                    ctlog:
                      ignoreSCT: true
          mutateDigest: true
          required: true
