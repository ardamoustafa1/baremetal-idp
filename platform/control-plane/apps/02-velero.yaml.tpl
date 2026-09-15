# =============================================================================
# sync-wave 2 — Velero (K8s obje/PV yedekleme, Ceph RGW birincil hedef)
#
# !!! OTOMATİK SYNC KASITLI OLARAK KAPALI (syncPolicy.automated YOK) !!!
# AYNI GEREKÇE: 01-loki.yaml.tpl — bu chart'ın values.yaml.tpl'i
# `velero-credentials` Secret'ını (Rook OBC'nin ürettiği S3 kimlik bilgileri,
# isteğe bağlı offsite profili DAHİL) REFERANS ALIR. Bu değerler CLUSTER'A
# ÖZGÜDÜR ve Git'e ASLA yazılmaz — `06-velero.sh` bunları okuyup Secret'ı
# doğrudan `kubectl apply` ile oluşturur ve `helm upgrade --install`'ı
# DOĞRUDAN çalıştırır. Bu Application, ArgoCD'nin bu kurulumu SONRADAN
# DEVRALMASI (adoption) içindir.
#
# DÜZELTME (Faz 12h, code review #11): bu Application ÖNCEDEN HİÇ YOKTU —
# `platform/control-plane/velero/` boştu, README "⬜ Sıradaki" işaretliydi.
# `compositions/`'ların kendisi Velero'ya DOĞRUDAN bağımlı değildir (Velero
# tenant kaynaklarını DIŞARIDAN, ayrı bir mekanizmayla yedekler) ama
# `platform/underlay/storage-classes/storageclasses.yaml.tpl`'in
# `reclaimPolicy: Delete` kararı AÇIKÇA "Kurtarma yolu Velero'dur" diyor —
# Velero kurulu OLMADAN bu karar GEÇERSİZDİ.
#
# DÜZELTME (Faz 12k, code review #13): `valueFiles` ÖNCEDEN ham
# `values.yaml.tpl`'e (envsubst edilmemiş ${CEPH_OBJECTSTORE_NAME} İÇEREN)
# işaret ediyordu — Helm'in `$values` ref source'u dosyayı OLDUĞU GİBİ
# git'ten okur, envsubst UYGULAMAZ. Manuel kurulum (`06-velero.sh`, GERÇEK
# değerlerle render eder) ile ArgoCD'nin GÖRDÜĞÜ değerler FARKLIYDI — bu
# Application SONRADAN devralınırsa (adoption) bozuk bir S3 endpoint'i
# uygulardı. Artık `render-app-manifests.sh`'in ÜRETTİĞİ (bu dizinin
# diğer .tpl'leriyle AYNI desende, git'e COMMIT edilen) gerçek `values.yaml`
# kullanılıyor — 06-velero.sh'in KENDİ envsubst render'ıyla (`rendered/
# values.yaml`, gitignored) AYNI kaynak `.tpl` dosyasından üretildiği için
# İÇERİK olarak AYNI.
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
  labels:
    platform.internal/layer: control-plane
  annotations:
    argocd.argoproj.io/sync-wave: "2"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    - repoURL: "${VELERO_HELM_REPO}"
      chart: velero
      targetRevision: "${VELERO_CHART_VERSION}"
      helm:
        releaseName: velero
        valueFiles:
          - $values/platform/control-plane/velero/values.yaml
          # KÜME-DIŞI (offsite) ikincil hedef İSTEĞE BAĞLIDIR (.env'de
          # VELERO_OFFSITE_ENABLED) — 06-velero.sh bunu KENDİ helm
          # upgrade'ine yalnızca etkinse ekler. Bu satırı AYNI şekilde
          # yalnızca offsite'ı ETKİNLEŞTİRDİĞİNİZDE (render-app-
          # manifests.sh'i VELERO_OFFSITE_* dolu .env ile çalıştırdıktan
          # SONRA) yorumdan çıkarın — aksi halde ArgoCD, boş/hatalı
          # offsite değerleriyle render edilmiş bir dosyayı uygulardı.
          # - $values/platform/control-plane/velero/values-offsite.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/control-plane/velero/resources
      directory:
        recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
    # automated: KASITLI OLARAK YOK — yukarıdaki uyarıya bakın.
