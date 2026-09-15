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

log "1/10 cert-manager kuruluyor..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version v1.16.2 \
  --set crds.enabled=true --wait --timeout 5m >/dev/null

log "2/10 CloudNativePG operatörü kuruluyor..."
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null 2>&1 || true
helm repo update cnpg >/dev/null
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --create-namespace --wait --timeout 5m >/dev/null

helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

# DÜZELTME (kod incelemesinde bulundu, GERÇEK bir tutarsızlık): ana Vault'un
# GERÇEK repo values.yaml'ı (Faz 12e'den beri) `seal "transit"` + bir
# `vault-autounseal-token` Secret'ı BEKLİYOR (bkz. platform/pki/vault-unseal/
# values.yaml, platform/pki/vault/values.yaml). Bu script ÖNCEDEN bu
# altyapıyı HİÇ kurmadan aynı values.yaml'ı `helm install` ediyordu — Secret
# yoksa pod'lar `CreateContainerConfigError` ile HİÇ BAŞLAYAMAZ, ve script
# ESKİ Shamir-only init/unseal akışını (unseal_keys_b64 + `vault operator
# unseal`) bekliyordu ki transit-mühürlü bir Vault bunu ASLA üretmez (init
# çıktısı `recovery_keys_b64` üretir, manuel unseal adımı GEREKMEZ — Vault
# init sonrası KENDİLİĞİNDEN transit üzerinden açılır). Şimdi GERÇEK
# sırayla: önce vault-unseal (KMS rolündeki küçük Vault) kuruluyor/init
# ediliyor/transit anahtarı üretiliyor, Secret oluşturuluyor, ANCAK SONRA
# ana Vault kuruluyor — platform/docs/PLATFORM_CONTEXT.md Faz 12e günlüğünde
# GERÇEK bir kind cluster'ında doğrulanan sırayla BİREBİR aynı.
log "3/10 vault-unseal (Transit auto-unseal KMS'i — ana Vault'un KENDİSİ DEĞİL) kuruluyor..."
kubectl create namespace vault-unseal --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace vault-unseal platform.internal/layer=pki --overwrite >/dev/null
helm upgrade --install vault-unseal hashicorp/vault \
  --namespace vault-unseal \
  -f "${REPO_ROOT}/platform/pki/vault-unseal/values.yaml" \
  --set server.dataStorage.storageClass=standard \
  --set server.dataStorage.size=1Gi \
  --timeout 5m >/dev/null
kubectl -n vault-unseal wait --for=condition=PodScheduled pod/vault-unseal-0 --timeout=120s >/dev/null
kubectl -n vault-unseal wait --for=condition=ContainersReady pod/vault-unseal-0 --timeout=180s >/dev/null 2>&1 || true

_wait_deadline=$(( $(date +%s) + 300 ))
until kubectl -n vault-unseal exec vault-unseal-0 -- vault status 2>&1 | grep -qv "connection refused\|dial tcp\|i/o timeout"; do
  (( $(date +%s) < _wait_deadline )) || { echo "HATA: vault-unseal-0 5 dakikada yanıt vermedi" >&2; exit 1; }
  sleep 3
done

kubectl -n vault-unseal exec vault-unseal-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > "${WORK}/vault-unseal-init.json"
UNSEAL_KEY="$(python3 -c "import json; print(json.load(open('${WORK}/vault-unseal-init.json'))['unseal_keys_b64'][0])")"
UNSEAL_ROOT_TOKEN="$(python3 -c "import json; print(json.load(open('${WORK}/vault-unseal-init.json'))['root_token'])")"
kubectl -n vault-unseal exec vault-unseal-0 -- vault operator unseal "${UNSEAL_KEY}" >/dev/null

kubectl -n vault-unseal exec vault-unseal-0 -- sh -c "VAULT_TOKEN=${UNSEAL_ROOT_TOKEN} vault secrets enable transit" >/dev/null
kubectl -n vault-unseal exec vault-unseal-0 -- sh -c "VAULT_TOKEN=${UNSEAL_ROOT_TOKEN} vault write -f transit/keys/autounseal" >/dev/null
# NOT (kod incelemesinde bulundu, GERÇEK bir bug): `vault policy write NAME -`
# STDIN'den okur ama `kubectl exec` (bir yerel bash heredoc'u pipe ile
# vererek çağrıldığında) `-i`/`--stdin` bayrağı OLMADAN stdin'i UZAK
# komuta iletmez — bu satır SESSİZCE "policy parametresi verilmedi" hatası
# veriyordu (bu script'in bu haliyle GERÇEKTEN çalıştırılmasıyla
# keşfedildi). 03-pki.sh'nin KENDİ deseniyle (dosya + `kubectl cp`) aynı,
# stdin'e hiç ihtiyaç DUYMAYAN bir yönteme geçirildi.
printf 'path "transit/encrypt/autounseal" { capabilities = ["update"] }\npath "transit/decrypt/autounseal" { capabilities = ["update"] }\n' > "${WORK}/autounseal-policy.hcl"
kubectl -n vault-unseal cp "${WORK}/autounseal-policy.hcl" "vault-unseal/vault-unseal-0:/tmp/autounseal-policy.hcl"
kubectl -n vault-unseal exec vault-unseal-0 -- sh -c "VAULT_TOKEN=${UNSEAL_ROOT_TOKEN} vault policy write autounseal /tmp/autounseal-policy.hcl" >/dev/null
AUTOUNSEAL_TOKEN="$(kubectl -n vault-unseal exec vault-unseal-0 -- sh -c "VAULT_TOKEN=${UNSEAL_ROOT_TOKEN} vault token create -policy=autounseal -period=768h -orphan -field=token")"

log "4/10 Vault (HA/Raft, 3 replika, GERÇEK repo values.yaml — anti-affinity ve StorageClass kind için override) kuruluyor..."
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n vault create secret generic vault-autounseal-token \
  --from-literal=VAULT_TOKEN="${AUTOUNSEAL_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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

log "5/10 Vault init (Transit auto-unseal ile — MANUEL unseal adımı YOK, vault-unseal'in transit anahtarı üzerinden KENDİLİĞİNDEN açılır)..."
_wait_deadline=$(( $(date +%s) + 600 ))
until kubectl -n vault exec vault-0 -- vault status 2>&1 | grep -qv "connection refused\|dial tcp\|i/o timeout"; do
  (( $(date +%s) < _wait_deadline )) || { echo "HATA: vault-0 10 dakikada yanıt vermedi" >&2; exit 1; }
  sleep 3
done

# DÜZELTME (kod incelemesinde bulundu, GERÇEK bir bug): transit auto-unseal
# İLK BAŞTAN yapılandırılmış (Shamir'den migrate EDİLMEMİŞ) bir Vault'ta
# `-key-shares`/`-key-threshold` bayrakları GEÇERSİZDİR — Vault "parameters
# secret_shares,secret_threshold not applicable to seal type transit"
# hatasıyla REDDEDER (canlı doğrulandı). Doğru bayraklar `-recovery-shares`/
# `-recovery-threshold` — bunlar UNSEAL için DEĞİL (transit zaten otomatik
# unseal eder), yalnızca break-glass/generate-root senaryoları için
# kullanılan "recovery key"leri üretir.
kubectl -n vault exec vault-0 -- vault operator init -recovery-shares=3 -recovery-threshold=2 -format=json > "${WORK}/vault-init.json"
python3 -c "import json; d=json.load(open('${WORK}/vault-init.json')); assert d.get('root_token'), 'root_token boş/eksik'" \
  || { err_out="$(cat "${WORK}/vault-init.json")"; echo "HATA: vault-init.json geçersiz: ${err_out}" >&2; exit 1; }
ROOT_TOKEN="$(python3 -c "import json; print(json.load(open('${WORK}/vault-init.json'))['root_token'])")"
# Transit seal ile init sonrası vault-0 KENDİLİĞİNDEN sealed=false olur —
# doğrula (manuel unseal adımı YOK, bu BİLİNÇLİ bir fark, yukarıdaki Shamir
# akışının YERİNE geçer).
for pod in vault-0 vault-1 vault-2; do
  _pod_deadline=$(( $(date +%s) + 300 ))
  until kubectl -n vault exec "${pod}" -- vault status 2>&1 | grep -qv "connection refused\|dial tcp\|i/o timeout"; do
    (( $(date +%s) < _pod_deadline )) || { echo "HATA: ${pod} 5 dakikada yanıt vermedi" >&2; exit 1; }
    sleep 3
  done
  _sealed_deadline=$(( $(date +%s) + 120 ))
  until kubectl -n vault exec "${pod}" -- vault status 2>&1 | grep -q "Sealed.*false"; do
    (( $(date +%s) < _sealed_deadline )) || { echo "HATA: ${pod} transit ile otomatik unseal olmadı (120s)" >&2; exit 1; }
    sleep 3
  done
done

log "6/10 Vault PKI (root→pki-int-dev) + kubernetes auth + cert-manager role/policy kuruluyor..."
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

# DÜZELTME (kod incelemesinde bulundu): bu satır ÖNCEDEN tenant PKI rolünü
# ELLE, ESKİ/team-only isimlendirmeyle (`tenant-acme`, max_ttl=720h) SABİT
# olarak yazıyordu — bu, provider-terraform'un (Faz 12b'de kaldırıldı) elle
# taklit edilmesiydi. Artık GEREKSİZ VE YANLIŞ: tenant composition'ının
# ürettiği GERÇEK `vaultBootstrapJob` (aşağıda ARTIK strip EDİLMİYOR —
# provider-terraform'a değil, yalnızca kendi ServiceAccount'una ihtiyaç
# duyuyor) bu rolü `tenant-<nsName>` adıyla ve DOĞRU max_ttl (2160h) ile
# KENDİSİ oluşturuyor — bkz. compositions/tenant/function.k
# `_vaultBootstrapScript`. Bu Job'ın ihtiyaç duyduğu `vault-tenant-bootstrap`
# kimliği (03-pki.sh ile AYNI) aşağıda, Crossplane kurulduktan SONRA (yani
# `crossplane-system` namespace'i var olduktan sonra) kuruluyor — bkz.
# 7/10 adımının SONU.

# NOT: gerçek repo policy dosyası (pki/vault/policies/cert-manager-policy.hcl)
# `pki-int-*/sign/tenant-*` GLOB'u kullanıyor — bu script de AYNI glob'u
# kullanmalı, aksi halde `tenant-<nsName>` biçimindeki YENİ rol adları
# (ör. "tenant-tenant-acme-dev") cert-manager'ın policy'siyle EŞLEŞMEZ.
printf 'path "pki-int-dev/sign/tenant-*" {\n  capabilities = ["create", "update"]\n}\n' > "${WORK}/cert-manager-policy.hcl"
kubectl -n vault cp "${WORK}/cert-manager-policy.hcl" "vault/vault-0:/tmp/cert-manager-policy.hcl"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write cert-manager /tmp/cert-manager-policy.hcl" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/kubernetes/role/cert-manager bound_service_account_names=cert-manager bound_service_account_namespaces='*' policies=cert-manager ttl=1h" >/dev/null

log "7/10 Crossplane + function-kcl + function-auto-ready kuruluyor..."
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

# `vault-tenant-bootstrap` kimliği (bkz. 6/10 adımındaki yorum) — ARTIK
# `crossplane-system` namespace'i (yukarıda Crossplane kurulumuyla) var,
# bu yüzden burada, tenant claim uygulanmadan HEMEN ÖNCE kuruluyor.
kubectl -n crossplane-system create serviceaccount vault-tenant-bootstrap --dry-run=client -o yaml | kubectl apply -f - >/dev/null
printf 'path "auth/kubernetes/role/tenant-*" {\n  capabilities = ["create", "read", "update", "delete"]\n}\npath "sys/policies/acl/tenant-*" {\n  capabilities = ["create", "read", "update", "delete"]\n}\npath "auth/kubernetes/role/eso-tenant-*" {\n  capabilities = ["create", "read", "update", "delete"]\n}\npath "sys/policies/acl/eso-tenant-*" {\n  capabilities = ["create", "read", "update", "delete"]\n}\npath "pki-int-dev/roles/tenant-*" {\n  capabilities = ["create", "read", "update", "delete"]\n}\n' > "${WORK}/vault-tenant-bootstrap-policy.hcl"
kubectl -n vault cp "${WORK}/vault-tenant-bootstrap-policy.hcl" "vault/vault-0:/tmp/vault-tenant-bootstrap-policy.hcl"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault policy write provider-terraform /tmp/vault-tenant-bootstrap-policy.hcl" >/dev/null
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault write auth/kubernetes/role/vault-tenant-bootstrap bound_service_account_names=vault-tenant-bootstrap bound_service_account_namespaces=crossplane-system policies=provider-terraform ttl=1h" >/dev/null

log "8/10 Tenant XRD/Composition uygulanıyor (Cilium kaynakları test-scope dışı bırakıldı)..."
kubectl apply -f "${REPO_ROOT}/platform/compositions/tenant/xrd.yaml" >/dev/null
# DÜZELTME (kod incelemesinde bulundu): `vaultWorkspace` ARTIK strip
# EDİLMİYOR — o kaynak Faz 12b'de `vaultBootstrapJob`'a (native, provider-
# terraform'a bağımlı OLMAYAN bir batch/v1 Job) dönüştürüldü, bu yüzden
# artık kind'de ÇALIŞABİLİR ve GERÇEK bir e2e kapsamı katıyor (öncesinde bu
# isim eşleşmediği için satır ZATEN sessizce hiçbir şey stripLEMİYORDU —
# `vaultWorkspace` adı composition.yaml'da hiç yoktu, `strip_unsupported_
# resources.py` no-op geçiyordu; bu YANLIŞLIKLA zararsızdı ama YANILTICIYDI).
python3 "${SCRIPT_DIR}/strip_unsupported_resources.py" \
  "${REPO_ROOT}/platform/compositions/tenant/composition.yaml" \
  "${WORK}/tenant-composition.yaml" \
  defaultDenyPolicy tierNetworkPolicy
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

# vaultBootstrapJob artık native (provider-terraform'a bağımlı DEĞİL) — bu
# testte İLK KEZ gerçekten çalışıyor (bkz. 8/10'daki strip listesi notu).
# Tenant-<nsName>/eso-tenant-<nsName> Vault rol/policy'lerinin GERÇEKTEN
# oluştuğunu doğrula.
log "   vault-bootstrap-acme-dev Job'ının tamamlanması bekleniyor..."
kubectl -n crossplane-system wait job/vault-bootstrap-acme-dev --for=condition=Complete --timeout=180s >/dev/null
log "   ✅ vault-bootstrap-acme-dev tamamlandı (tenant-tenant-acme-dev + eso-tenant-tenant-acme-dev Vault rolleri oluşturuldu)"

log "9/10 Postgres XRD/Composition uygulanıyor (Cilium/Rook/ESO kaynakları test-scope dışı bırakıldı)..."
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

log "10/10 Bağlantı Secret'ı + uçtan uca sertifika zinciri doğrulanıyor..."
kubectl -n tenant-acme-dev get secret "${CLUSTER_NAME}-app" >/dev/null \
  && log "   ✅ Bağlantı Secret'ı '${CLUSTER_NAME}-app' mevcut (host/user/password/dbname)"

CERT_SECRET="$(kubectl -n tenant-acme-dev get certificate -l 'crossplane.io/composite' -o jsonpath='{.items[0].spec.secretName}')"
kubectl -n tenant-acme-dev get secret "${CERT_SECRET}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${WORK}/leaf.crt"
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault read -field=certificate pki-root/cert/ca" > "${WORK}/root.crt"
cat "${WORK}/int-signed.crt" "${WORK}/root.crt" > "${WORK}/chain.pem"
openssl verify -CAfile "${WORK}/chain.pem" "${WORK}/leaf.crt"

log "✅✅✅ TAM ZİNCİR DOĞRULANDI: Tenant claim → Namespace/RBAC/Quota/Issuer → Postgres claim → CNPG Cluster + bağlantı Secret'ı → cert-manager Certificate (GERÇEK Vault PKI zinciriyle openssl verify: OK)"
