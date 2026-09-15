#!/usr/bin/env bash
# =============================================================================
# Uçtan uca zincir testi: Tenant claim → Postgres claim → bağlantı → cert
# doğrulama. Faz 11, görev madde 3. kind tabanlı bir test cluster'ında
# ÇALIŞIR (gerçek Rook-Ceph/Cilium/Vault-Terraform bare-metal kurulumu
# GEREKTİRMEZ) — CI'da `platform-ci.yaml`'ın `e2e-chain-test` job'ı
# bunu, önce boş bir `kind create cluster` ile çağırır.
#
# BU SCRIPT'İN KAPSAMI VE SINIRLARI (bkz. README.md için tam liste):
# gerçek Tenant/Postgres composition.yaml dosyaları KULLANILIR ama
# Cilium/Rook-Ceph/ESO/provider-terraform'a bağımlı 7 kaynak (bkz. aşağıdaki
# "ÇIKARILAN KAYNAKLAR") kind'de bu bileşenler kurulu OLMADIĞI için bir
# ÇALIŞMA-ZAMANI patch'iyle composition'ın `items` listesinden çıkarılır.
# Bu patch REPO'DAKİ gerçek composition.yaml dosyasını DEĞİŞTİRMEZ — yalnızca
# bu script'in kind cluster'ına uyguladığı GEÇİCİ bir kopya üzerinde çalışır.
#
# GERÇEKTEN TEST EDİLEN ZİNCİR:
#   Tenant claim → Namespace/RBAC/Quota/LimitRange/SA/Issuer (Vault-backed,
#   GERÇEK Vault PKI'ya karşı) → Postgres claim → CNPG Cluster (gerçek
#   failover kapasiteli) + Certificate (AYNI Vault Issuer'dan GERÇEKTEN
#   imzalanmış) → bağlantı Secret'ı (CNPG'nin ürettiği `<name>-app` Secret'ı).
#
# ÇIKARILAN KAYNAKLAR (kind'de karşılığı yok, gerçek bare-metal kurulumda
# BUNLAR DA test edilmelidir — bkz. chainsaw e2e testleri,
# compositions/{tenant,postgresql}/tests/e2e/):
#   Tenant:      defaultDenyPolicy, tierNetworkPolicy (Cilium CRD gerekir)
#                vaultWorkspace (provider-terraform gerekir — bu script Vault
#                PKI rolünü/policy'sini DOĞRUDAN `vault write` ile kurar,
#                Terraform'un otomasyonunu MANUEL olarak taklit eder)
#   Postgres:    backupBucket (Rook-Ceph OBC), scheduledBackup (aynı sebep),
#                networkPolicy (Cilium), serviceMonitor (kube-prometheus-stack
#                CRD'si), secretStore/pushSecret/externalSecret (ESO+Vault
#                kv/ mount'u — bağlantı sırrının Vault'a round-trip'i)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

log() { printf '[e2e-chain] %s\n' "$*"; }

log "1/9 cert-manager kuruluyor..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.16.2 \
  --set crds.enabled=true --wait --timeout 5m >/dev/null

log "2/9 CloudNativePG operatörü kuruluyor..."
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait --timeout 5m >/dev/null

log "3/9 Vault (HA/Raft, 3 replika, GERÇEK repo values.yaml — anti-affinity ve StorageClass kind için override) kuruluyor..."
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# NOT: `server.livenessProbe.initialDelaySeconds` 300'e YÜKSELTİLDİ (repo
# değeri 60) — YALNIZCA bu test cluster'ı için. Gerçek repo değeri (60),
# init/unseal'in İNSAN eliyle dakikalar içinde yapıldığı bir bare-metal
# kurulumda sorun DEĞİLDİR; ama bu OTOMATİK script'te init birkaç ekstra
# adımdan (PKI mount, k8s-auth) sonra tetiklenebildiği için, liveness
# probe'un henüz init edilmemiş bir pod'u "unhealthy" sayıp ÖLDÜRMESİ,
# init'in HİÇ tamamlanamadığı bir crash-loop'a yol açabiliyordu (bu script
# GERÇEKTEN çalıştırılırken keşfedilen bir bulgu — bkz. PLATFORM_CONTEXT.md
# Faz 12 günlüğü).
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  -f "${REPO_ROOT}/platform/pki/vault/values.yaml" \
  --set server.dataStorage.storageClass=standard \
  --set server.auditStorage.storageClass=standard \
  --set server.dataStorage.size=1Gi \
  --set server.auditStorage.size=1Gi \
  --set server.affinity="" \
  --set server.livenessProbe.initialDelaySeconds=300 \
  --timeout 5m >/dev/null
kubectl -n vault wait --for=condition=PodScheduled pod/vault-0 pod/vault-1 pod/vault-2 --timeout=120s >/dev/null
kubectl -n vault wait --for=condition=ContainersReady pod/vault-0 pod/vault-1 pod/vault-2 --timeout=180s >/dev/null 2>&1 || true

log "4/9 Vault init/unseal (3 paylaşım/2 eşik — YALNIZCA bu test cluster'ı için, üretimde 5/3 — bkz. vault-unseal.md)..."
# vault-0'ın GERÇEKTEN yanıt verdiğini (init için hazır) bekle — sabit bir
# `sleep` yerine gerçek bir hazır-olma kontrolü (bu script'in bir önceki
# denemesinde `sleep 20` yetersiz kaldığı için init yarım kalmıştı — bkz.
# PLATFORM_CONTEXT.md Faz 12 günlüğü, "run.sh'deki gerçek bug").
# `vault status` sealed/uninitialized durumlarda da NONZERO exit code
# döner — bu yüzden exit code'a değil, GERÇEK bir Vault yanıtı alıp
# almadığımıza (bağlantı hatası METNİ YOK) bakıyoruz. Üst sınır (10dk) —
# sonsuz döngü YERİNE net bir hata (bu script'in bir denemesinde bu adımın
# beklenenden UZUN sürdüğü gözlemlendi — bkz. PLATFORM_CONTEXT.md Faz 12
# günlüğü).
_wait_deadline=$(( $(date +%s) + 600 ))
until kubectl -n vault exec vault-0 -- vault status 2>&1 | grep -qv "connection refused\|dial tcp\|i/o timeout"; do
  (( $(date +%s) < _wait_deadline )) || { echo "HATA: vault-0 10 dakikada yanıt vermedi" >&2; exit 1; }
  sleep 3
done

kubectl -n vault exec vault-0 -- vault operator init -key-shares=3 -key-threshold=2 -format=json > "${WORK}/vault-init.json"
python3 -c "import json; d=json.load(open('${WORK}/vault-init.json')); assert d.get('root_token'), 'root_token boş/eksik'" \
  || { err_out="$(cat "${WORK}/vault-init.json")"; echo "HATA: vault-init.json geçersiz: ${err_out}" >&2; exit 1; }
KEY1="$(python3 -c "import json; print(json.load(open('${WORK}/vault-init.json'))['unseal_keys_b64'][0])")"
KEY2="$(python3 -c "import json; print(json.load(open('${WORK}/vault-init.json'))['unseal_keys_b64'][1])")"
ROOT_TOKEN="$(python3 -c "import json; print(json.load(open('${WORK}/vault-init.json'))['root_token'])")"
for pod in vault-0 vault-1 vault-2; do
  _pod_deadline=$(( $(date +%s) + 300 ))
  until kubectl -n vault exec "${pod}" -- vault status 2>&1 | grep -qv "connection refused\|dial tcp\|i/o timeout"; do
    (( $(date +%s) < _pod_deadline )) || { echo "HATA: ${pod} 5 dakikada yanıt vermedi" >&2; exit 1; }
    sleep 3
  done
  kubectl -n vault exec "${pod}" -- sh -c "vault operator unseal ${KEY1} >/dev/null && vault operator unseal ${KEY2}" >/dev/null
done

log "5/9 Vault PKI (root→pki-int-dev) + kubernetes auth + cert-manager role/policy kuruluyor..."
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault auth enable kubernetes" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault secrets enable -path=pki-root pki" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault secrets tune -max-lease-ttl=87600h pki-root" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write -field=certificate pki-root/root/generate/internal common_name=platform-root ttl=87600h" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault secrets enable -path=pki-int-dev pki" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault secrets tune -max-lease-ttl=17520h pki-int-dev" >/dev/null

kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write -format=json pki-int-dev/intermediate/generate/internal common_name=platform-int-dev" > "${WORK}/int-gen.json"
python3 -c "import json; open('${WORK}/int.csr','w').write(json.load(open('${WORK}/int-gen.json'))['data']['csr'])"
kubectl -n vault cp "${WORK}/int.csr" "vault/vault-0:/tmp/int.csr"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write -format=json pki-root/root/sign-intermediate csr=@/tmp/int.csr format=pem_bundle ttl=17520h" > "${WORK}/int-signed.json"
python3 -c "import json; open('${WORK}/int-signed.crt','w').write(json.load(open('${WORK}/int-signed.json'))['data']['certificate'] + chr(10))"
kubectl -n vault cp "${WORK}/int-signed.crt" "vault/vault-0:/tmp/int-signed.crt"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write pki-int-dev/intermediate/set-signed certificate=@/tmp/int-signed.crt" >/dev/null

kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write pki-int-dev/roles/tenant-acme allowed_domains=tenant-acme-dev.svc.cluster.local allow_subdomains=true allow_bare_domains=false max_ttl=720h" >/dev/null
printf 'path "pki-int-dev/sign/tenant-acme" {\n  capabilities = ["create", "update"]\n}\n' > "${WORK}/cert-manager-policy.hcl"
kubectl -n vault cp "${WORK}/cert-manager-policy.hcl" "vault/vault-0:/tmp/cert-manager-policy.hcl"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write cert-manager /tmp/cert-manager-policy.hcl" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/kubernetes/role/cert-manager bound_service_account_names=cert-manager bound_service_account_namespaces='*' policies=cert-manager ttl=1h" >/dev/null

log "6/9 Crossplane + function-kcl + function-auto-ready kuruluyor..."
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update crossplane-stable >/dev/null
# !!! KRİTİK: versions.env CROSSPLANE_CHART_VERSION="1.18.0" BU TESTTE
# KULLANILMAZ — 1.18.0'ın CompositeResourceDefinition v1 reconciler'ı,
# namespaced composed kaynaklar için `resourceRefs[].namespace` alanını
# YAZMAYA ÇALIŞIR ama üretilen CRD şeması bu alanı TANIMLAMAZ (gerçek hata:
# "field not declared in schema") — bu görevde GERÇEKTEN test edilerek
# keşfedilen kritik bir sürüm uyumsuzluğu (bkz. PLATFORM_CONTEXT.md Faz 11
# günlüğü ve teknik borç tablosu). 2.4.0 bu sorunu GERÇEKTEN çözüyor.
helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system --create-namespace --version 2.4.0 \
  --wait --timeout 5m >/dev/null

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-kcl
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-kcl:v0.10.0
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.5.0
EOF
kubectl wait function.pkg.crossplane.io/function-kcl function.pkg.crossplane.io/function-auto-ready \
  --for=condition=Healthy --timeout=120s >/dev/null

# Bu TEST cluster'ında Crossplane'in composed kaynakları (Namespace/Role/
# RoleBinding/vb.) doğrudan uygulayabilmesi için cluster-admin — GERÇEK
# platformda bu izin provider-kubernetes/helm'e verilir (bkz. control-plane/
# README.md teknik borç #12); burada Crossplane çekirdeği doğrudan
# uyguladığı için AYNI genişlikte izin, YALNIZCA bu izole test cluster'ında.
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: crossplane-e2e-test-cluster-admin
subjects:
  - kind: ServiceAccount
    name: crossplane
    namespace: crossplane-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# ceph-block, gerçek platformda Rook-Ceph StorageClass'ıdır — kind'de
# local-path provisioner'a alias'lanır (yalnızca bu test için).
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-block
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF

log "7/9 Tenant XRD/Composition uygulanıyor (Cilium/Terraform kaynakları test-scope dışı bırakıldı)..."
kubectl apply -f "${REPO_ROOT}/platform/compositions/tenant/xrd.yaml" >/dev/null
python3 "${SCRIPT_DIR}/strip_unsupported_resources.py" \
  "${REPO_ROOT}/platform/compositions/tenant/composition.yaml" \
  "${WORK}/tenant-composition.yaml" \
  defaultDenyPolicy tierNetworkPolicy vaultWorkspace
kubectl apply -f "${WORK}/tenant-composition.yaml" >/dev/null

kubectl create namespace tenant-requests --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f "${REPO_ROOT}/platform/compositions/tenant/examples/tenant-acme-dev.yaml" >/dev/null
kubectl wait namespace/tenant-acme-dev --for=jsonpath='{.status.phase}'=Active --timeout=120s >/dev/null

# Issuer'ın Vault kubernetes-auth ile çalışması için ZORUNLU olan
# "cert-manager" ServiceAccount + token-mint RBAC'ı — composition BUNU
# ÜRETMEZ (bkz. PLATFORM_CONTEXT.md teknik borç: "Issuer, var olmayan bir
# ServiceAccount'a referans veriyor").
kubectl create serviceaccount cert-manager -n tenant-acme-dev --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cert-manager-tokenrequest
  namespace: tenant-acme-dev
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts/token"]
    resourceNames: ["cert-manager"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cert-manager-tokenrequest
  namespace: tenant-acme-dev
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: cert-manager
roleRef:
  kind: Role
  name: cert-manager-tokenrequest
  apiGroup: rbac.authorization.k8s.io
EOF

log "   tenant-issuer'ın Ready olması bekleniyor..."
until kubectl -n tenant-acme-dev get issuer tenant-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  sleep 5
  kubectl -n tenant-acme-dev annotate issuer tenant-issuer force-resync="$(date +%s)" --overwrite >/dev/null 2>&1 || true
done
log "   ✅ tenant-issuer Ready (Vault verified)"

log "8/9 Postgres XRD/Composition uygulanıyor (Cilium/Rook/ESO kaynakları test-scope dışı bırakıldı)..."
kubectl apply -f "${REPO_ROOT}/platform/compositions/postgresql/xrd.yaml" >/dev/null
python3 "${SCRIPT_DIR}/strip_unsupported_resources.py" \
  "${REPO_ROOT}/platform/compositions/postgresql/composition.yaml" \
  "${WORK}/postgresql-composition.yaml" \
  backupBucket scheduledBackup networkPolicy serviceMonitor secretStore pushSecret externalSecret
kubectl apply -f "${WORK}/postgresql-composition.yaml" >/dev/null

kubectl apply -f "${REPO_ROOT}/platform/compositions/postgresql/examples/postgresql-small.yaml" >/dev/null

log "   Certificate'ın Ready olması bekleniyor..."
until kubectl -n tenant-acme-dev get certificate -l 'crossplane.io/composite' -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  sleep 5
done
log "   ✅ Postgres server Certificate Ready (aynı Vault Issuer'dan imzalandı)"

log "   CNPG Cluster'ın sağlıklı olması bekleniyor (birkaç dakika sürebilir)..."
until kubectl -n tenant-acme-dev get cluster -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; do
  sleep 10
done
CLUSTER_NAME="$(kubectl -n tenant-acme-dev get cluster -o jsonpath='{.items[0].metadata.name}')"
log "   ✅ CNPG Cluster '${CLUSTER_NAME}' healthy"

log "9/9 Bağlantı Secret'ı + uçtan uca sertifika zinciri doğrulanıyor..."
kubectl -n tenant-acme-dev get secret "${CLUSTER_NAME}-app" >/dev/null \
  && log "   ✅ Bağlantı Secret'ı '${CLUSTER_NAME}-app' mevcut (host/user/password/dbname)"

CERT_SECRET="$(kubectl -n tenant-acme-dev get certificate -l 'crossplane.io/composite' -o jsonpath='{.items[0].spec.secretName}')"
kubectl -n tenant-acme-dev get secret "${CERT_SECRET}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${WORK}/leaf.crt"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault read -field=certificate pki-root/cert/ca" > "${WORK}/root.crt"
cat "${WORK}/int-signed.crt" "${WORK}/root.crt" > "${WORK}/chain.pem"
openssl verify -CAfile "${WORK}/chain.pem" "${WORK}/leaf.crt"

log "✅✅✅ TAM ZİNCİR DOĞRULANDI: Tenant claim → Namespace/RBAC/Quota/Issuer → Postgres claim → CNPG Cluster + bağlantı Secret'ı → cert-manager Certificate (GERÇEK Vault PKI zinciriyle openssl verify: OK)"
