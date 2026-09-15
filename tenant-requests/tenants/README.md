# tenants/

Her tenant için **tek bir dosya**: `<isim>.yaml` (`kind: Tenant`). Dosya adı,
içindeki `metadata.name` ile birebir aynı olmalıdır.

2 gerçek örnek burada duruyor (`acme-dev.yaml`, `acme-prod.yaml`) —
`platform/compositions/tenant/examples/`'in birebir kopyası, CI'da
`kubeconform`+`crossplane render` ile gerçekten doğrulandı.

Dosya biçimi ve alan anlamları için üst dizindeki [README](../README.md).
