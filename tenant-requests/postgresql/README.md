# postgresql/

Her Postgres örneği için **tek bir dosya**: `<isim>.yaml`
(`kind: PostgreSQLInstance`). Dosya adı, içindeki `metadata.name` ile
birebir aynı olmalıdır.

2 gerçek örnek burada duruyor (`acme-cache-db.yaml` — small,
`acme-orders-db.yaml` — HA large) — `platform/compositions/postgresql/examples/`'in
birebir kopyası, CI'da gerçekten doğrulandı (`highAvailability=true` +
`size=small` kombinasyonu CI'da GERÇEKTEN reddedilir, bkz. workflow'un
kendi test geçmişi).

Dosya biçimi, geliştirici runbook'u: `platform/docs/runbooks/request-postgres.md`.
