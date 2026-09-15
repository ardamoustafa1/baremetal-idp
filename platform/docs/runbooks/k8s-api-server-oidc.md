# Runbook: Kubernetes API Server ↔ Keycloak OIDC Entegrasyonu

Bu, açık karar #13 / teknik borç #17'nin ÇÖZÜMÜDÜR: `XTenant`'ın
`oidcGroup` → RoleBinding akışının GERÇEKTEN çalışması için API server'ın
OIDC token'ları doğrulaması gerekir — bu, Faz 6'dan beri eksikti.

| Alan | Değer |
|---|---|
| Bağımlılık | Keycloak GERÇEKTEN kurulu ve **HTTPS ile** erişilebilir olmalı (bkz. §0) |
| Uygulama şekli | kubeadm `ClusterConfiguration` — kubeadm cluster'ın KENDİSİ kurulurken (veya `kubeadm upgrade`) uygulanır, GitOps akışının DIŞINDADIR |

## 0. Ön koşul: Keycloak TLS

K8s API server, OIDC issuer'ın `.well-known/openid-configuration`'ını
**HTTPS üzerinden** çekebilmelidir (`--oidc-issuer-url` HTTP'yi kabul
etmez). Bu, teknik borç #7'nin ("Keycloak `production: false`, TLS yok")
kapatılmasını ÖN KOŞUL yapar — `platform/control-plane/keycloak/
values.yaml.tpl`'e bir cert-manager Certificate + Ingress/Gateway TLS
termination eklenmeden bu runbook UYGULANAMAZ. (Bu, ayrı bir görev
kapsamında — teknik borç #7'nin kendisi — kapatılmalıdır; burada yalnızca
BAĞIMLILIK olarak işaretlenmiştir.)

## 1. Keycloak client

`platform/control-plane/keycloak/realm-platform.json.tpl`'e `kubernetes`
adlı PUBLIC bir client eklendi (bu görevde). Realm re-import edildiğinde
(`04-...` veya Keycloak Admin API ile) bu client otomatik oluşur.

## 2. kubeadm ClusterConfiguration

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
apiServer:
  extraArgs:
    oidc-issuer-url: "https://${KEYCLOAK_HOSTNAME}/realms/${KEYCLOAK_REALM}"
    oidc-client-id: "kubernetes"
    oidc-username-claim: "email"
    oidc-username-prefix: "oidc:"
    oidc-groups-claim: "groups"
    oidc-groups-prefix: "oidc:"
    # Keycloak'un TLS sertifikası platformun KENDİ Vault PKI'sinden
    # (pki-int-<env>) geliyorsa, API server'ın bu CA'ya GÜVENMESİ gerekir —
    # aksi halde issuer discovery HTTPS handshake'te başarısız olur.
    oidc-ca-file: "/etc/kubernetes/pki/platform-ca-bundle.crt"
  extraVolumes:
    - name: oidc-ca-bundle
      hostPath: /etc/kubernetes/pki/platform-ca-bundle.crt
      mountPath: /etc/kubernetes/pki/platform-ca-bundle.crt
      readOnly: true
      pathType: File
```

`platform-ca-bundle.crt`, Vault'un `pki-root/cert/ca` + `pki-int-<env>/
cert/ca` çıktılarının birleştirilmiş hâlidir (aynı `disaster-recovery.md`
ve `tests/e2e/kind-chain/run.sh`'in chain-verify adımlarında üretilen
zincirle AYNI mantık) — HER control-plane node'a KOPYALANMALIDIR.

## 3. `oidc:` prefix'i ile RBAC uyumu

`--oidc-username-prefix`/`--oidc-groups-prefix` KULLANILDIĞI için,
`platform/compositions/tenant/function.k`'nin ürettiği RoleBinding'in
`subjects[].name` alanı **`oidc:` önekiyle** eşleşmelidir. Bu, composition'a
BU görevde eklenen bir düzeltmedir (bkz. aşağıdaki "Composition
güncellemesi").

## 4. `kubectl` istemci tarafı

Kullanıcılar `kubectl-oidc_login` (int128/kubelogin) eklentisiyle
kimlik doğrular:

```bash
kubectl oidc-login setup \
  --oidc-issuer-url=https://${KEYCLOAK_HOSTNAME}/realms/${KEYCLOAK_REALM} \
  --oidc-client-id=kubernetes
```

`~/.kube/config`'e eklenen `exec` credential plugin'i, her `kubectl`
çağrısında (gerekirse) tarayıcıda Keycloak login akışını açar.

## 5. Doğrulama

```bash
kubectl --user=oidc get pods -n tenant-acme-dev
# Beklenen: RoleBinding'in subjects[].name = "oidc:tenant-acme" ile
# kullanıcının token'ındaki groups claim'i EŞLEŞTİĞİNDE erişim izni.
```

## 6. Bu görevde YAPILAN / YAPILAMAYAN

- ✅ Keycloak client eklendi, kubeadm config şablonu yazıldı, composition'ın
  RBAC subject'i `oidc:` prefix'iyle uyumlu hâle getirildi (bkz. aşağıda).
- ❌ **GERÇEK bir kubeadm control-plane node'unda UYGULANMADI** — bu,
  fiziksel/sanal bir control-plane node'a `kubeadm init`/`upgrade` ile
  müdahale gerektirir; bu ortamda böyle bir node YOK. Bu, platform
  mühendisliğinin çözebileceği bir tasarım sorunu OLMAKTAN ÇIKIP bir
  ALTYAPI sağlama sorununa dönüşür — bkz. PLATFORM_CONTEXT.md'nin "Bu
  ortamda tamamlanamayan kalemler" bölümü.
