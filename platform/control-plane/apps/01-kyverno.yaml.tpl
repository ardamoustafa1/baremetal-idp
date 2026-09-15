# =============================================================================
# sync-wave 1 — Kyverno (crossplane/eso ile PARALEL; hepsi underlay'e bağımlı,
# birbirlerine bağımlı değiller)
# =============================================================================
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kyverno
  namespace: argocd
  labels:
    platform.internal/layer: policies
  annotations:
    argocd.argoproj.io/sync-wave: "1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: platform
  sources:
    # NOT: repo/sürüm SOMUTLAŞTIRILDI (versions.env ile senkron tutun) — bkz.
    # 01-crossplane.yaml.tpl üstündeki gerekçe.
    - repoURL: "https://kyverno.github.io/kyverno"
      chart: kyverno
      targetRevision: "3.3.6"  # versions.env: KYVERNO_CHART_VERSION
      helm:
        releaseName: kyverno
        valueFiles:
          - $values/platform/control-plane/kyverno/values.yaml
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      ref: values
    # ClusterPolicy'ler — Kyverno CRD'leri kurulduktan sonra devreye girer
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/policies/validation
      directory:
        recurse: true
    # Faz 10'un güvenlik politikaları (imza doğrulama + cluster-wide PSS) —
    # KAPSAMLI-EKSİK-TAMAMLAMA GÖREVİNDE keşfedilen bir boşluk: bu politikalar
    # Faz 10'da yazıldı ama HİÇBİR ArgoCD Application'a bağlanmamıştı (04'ün
    # composition'ları için Faz 6→7 arasında yaşanan AYNI sınıf boşluk,
    # burada da tekrarlanmıştı). `pod-security-admission-configuration.yaml`
    # bir K8s API kaynağı DEĞİLDİR (kubeadm seviyesi statik dosya) — ArgoCD'nin
    # onu uygulamaya ÇALIŞIP "no matches for kind AdmissionConfiguration"
    # hatasıyla senkronizasyonu KIRMAMASI için `exclude` ile hariç tutuldu.
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/policies/security
      directory:
        recurse: false
        exclude: "pod-security-admission-configuration.yaml"
    # Politika-eşlik eden RBAC (`policies/rbac/`) — AYNI şekilde HİÇBİR
    # Application'a bağlı DEĞİLDİ (kapsamlı-eksik-tamamlama görevinde,
    # `enforce-unique-cost-center` politikasını GERÇEK bir cluster'da test
    # ederken keşfedildi: Kyverno'nun `context.apiCall`'ı bu RBAC olmadan
    # "unknown" hatasıyla başarısız olup TÜM Tenant claim'lerini reddediyordu).
    - repoURL: "${PLATFORM_REPO_URL}"
      targetRevision: "${PLATFORM_REPO_REVISION}"
      path: platform/policies/rbac
      directory:
        recurse: false
  destination:
    server: https://kubernetes.default.svc
    namespace: kyverno
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=true
    retry:
      limit: 8
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 5m
