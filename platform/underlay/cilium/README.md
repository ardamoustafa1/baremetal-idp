# Cilium — kurulum ve politika notları

ADR-0001 Karar 2.2.

## Ön koşul: kube-proxy olmadan kurulmuş cluster

```bash
kubeadm init \
  --skip-phases=addon/kube-proxy \
  --pod-network-cidr=10.244.0.0/16 \
  --control-plane-endpoint=<K8S_API_SERVER_HOST>:6443
```

Cluster kube-proxy **ile** kurulduysa, Cilium'dan önce kaldırın:

```bash
kubectl -n kube-system delete daemonset kube-proxy
kubectl -n kube-system delete configmap kube-proxy
# her node'da, kalan iptables kurallarını temizleyin:
iptables-save | grep -v KUBE- | iptables-restore
```

Script bu durumu tespit eder ve onay ister.

## Neden `k8sServiceHost` zorunlu

kube-proxy yokken, Cilium agent'ı `kubernetes.default.svc` ClusterIP'sini
çözemez — çünkü o ClusterIP'yi yönetecek olan **Cilium'un kendisidir**.
Yumurta-tavuk. Bu yüzden API server'ın gerçek adresi doğrudan verilir.

Bu iki değer yanlışsa arıza şöyle görünür: agent CrashLoopBackOff, log'da
`Unable to contact k8s api-server`. Değerler `.env`'den gelir.

## Ağ politikası katmanları

Dosyalar sıra numarasıyla adlandırılmıştır; **sıra anlamlıdır**:

| Dosya | Ne yapar | Ne zaman uygulanır |
|---|---|---|
| `ccnp-00-allow-dns.yaml` | Tüm pod'lara kube-dns erişimi + L7 DNS görünürlüğü | Her zaman |
| `ccnp-01-allow-health.yaml` | Cilium health endpoint trafiği | Her zaman |
| `ccnp-99-default-deny.yaml.tpl` | Cluster-wide default-deny | **Yalnızca `ENABLE_DEFAULT_DENY=true`** |

### default-deny açmadan önce

1. Tüm bileşenlerin sağlıklı olduğunu doğrulayın: `01-underlay.sh --verify-only`
2. Düşen akışları izlemeye başlayın:
   ```bash
   cilium hubble port-forward &
   hubble observe --verdict DROPPED --follow
   ```
3. `.env` → `ENABLE_DEFAULT_DENY=true`
4. `./platform/bootstrap/01-underlay.sh --only policies`
5. Script DNS smoke test'i çalıştırır. Başarısızsa **hemen** geri alın:
   ```bash
   kubectl delete ciliumclusterwidenetworkpolicy platform-default-deny
   ```

### Muafiyet listesi geçicidir

`DEFAULT_DENY_EXEMPT_NAMESPACES` şu an tüm platform namespace'lerini kapsar.
Bu, Faz 1'i ilerletmek için verilen bir tavizdir — her platform bileşeni
kendi açık politikasını aldığında liste daraltılmalıdır.
PLATFORM_CONTEXT.md teknik borç #3 bunu izler.

**Tenant namespace'leri (`tenant-*`) muafiyet listesine ASLA eklenmez.**

## Doğrulama

```bash
cilium status --wait                       # CLI varsa — asıl kontrol
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --brief
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
kubectl get gatewayclass                   # cilium GatewayClass Accepted olmalı
kubectl get ciliumclusterwidenetworkpolicy

# Hubble UI
kubectl -n kube-system port-forward svc/hubble-ui 12000:80
```

## Bilinçli kapatılan ayarlar

| Ayar | Değer | Neden |
|---|---|---|
| `l2announcements` | `false` | MetalLB bu işi yapıyor. İkisi açıkken ARP çakışır. |
| `bgpControlPlane` | `false` | Faz 1 L2 mode. BGP'ye geçişte burası ve MetalLB birlikte değişir. |
| `ingressController` | `false` | Kuzey-güney trafiği Gateway API üzerinden. |
| `bandwidthManager.bbr` | `false` | kernel ≥ 5.18 ister; node imajı standartlaşınca açılacak. |
| `*.serviceMonitor` | `false` | kube-prometheus-stack Faz 4'te geliyor. CRD yokken açmak sync hatası verir. |
