# L6 — Tenant API (Crossplane v2 + KCL)

Platformun **sözleşmesi**. Tenant'ın gördüğü tek yüzey burasıdır; altındaki
katmanların tamamı buradan gizlenir. ADR-0001 Karar 2.4.

| Dizin | İçerik | Durum |
|---|---|---|
| `tenant/` | `XTenant`/`Tenant` — namespace, RBAC, kota, ağ politikası, Vault, Issuer | ✅ Faz 6 |
| `postgresql/` | `XPostgreSQLInstance`/`PostgreSQLInstance` — CNPG Cluster, TLS, ağ politikası, ESO round-trip, yedekleme | ✅ Faz 7 |
| `bucket/`, … | Gelecek composition'lar (aynı desen: `xrd.yaml` + `composition.yaml` + `function.k`) | ⬜ planlandı |

## Gerçek yapı, Faz 0'ın planından NEDEN farklı

Faz 0'da `xrds/` + `functions/` + `kcl/` şeklinde **paylaşımlı, ayrı**
dizinler planlanmıştı (bkz. bu dosyanın git geçmişi). Faz 6'da `XTenant`'ı
yazarken bu ayrım terk edildi; bunun yerine **her composition kendi
dizininde, kendi kendine yeten** bir üçlü barındırıyor:

```
compositions/tenant/
├── xrd.yaml           # CompositeResourceDefinition (XTenant + Tenant claim)
├── composition.yaml   # Composition (mode: Pipeline, function-kcl adımı)
├── function.k         # KCL mantığı — composition.yaml'a BİREBİR GÖMÜLÜ kopyası var
├── examples/          # Gerçek kullanım şekli: Tenant CLAIM'leri
├── tests/
│   ├── functions.yaml         # function-kcl + function-auto-ready paket referansları
│   ├── render-examples.sh     # examples/'i render edip docs/examples-output/'a yazar
│   ├── verify-sync.sh         # function.k ↔ composition.yaml drift kontrolü
│   └── e2e/                   # chainsaw test (kabul kriterleri)
└── README.md
```

**Neden bu değişiklik yapıldı:** `function-kcl`'nin resmi/test edilebilir
"inline source" biçimi, KCL'i `Composition` YAML'ının içine GÖMMEYİ ister
(bkz. `tenant/README.md`). Ayrı bir `naming.k`/`tiers.k` paylaşımlı modülü,
KCL'in OCI/Git modül import mekanizmasını (bir registry'ye push edilmiş
paket) gerektirir — bu repoda henüz bir KCL modül registry'si YOK. Bu yüzden
Faz 6, naming/tier mantığını `tenant/function.k` içine **inline** yazdı.

**Kabul edilen teknik borç — artık İKİ composition'da:** Faz 7
(`postgresql/`), Faz 6.5'teki "ikinci composition'dan önce refactor et"
önerisine RAĞMEN yine inline mantıkla yazıldı (görev kapsamı dışında
bırakıldı, bilinçli bir erteleme). `_resAnno` lambda'sı ve etiket şeması
artık `tenant/function.k` ile `postgresql/function.k` arasında KOPYA.
Üçüncü composition (`bucket/` vb.) yazılmadan ÖNCE bu refactor'ın
YAPILMASI ZORUNLU hale geldi — borç artık ertelenemez boyuta ulaştı
(PLATFORM_CONTEXT.md teknik borç listesinde kayıtlı).

## Değişmez kurallar (Faz 0'dan korunanlar)

- Hiçbir composition kendi string birleştirmesini "rastgele" yapmaz —
  isimlendirme conventions.md §5'teki kalıplara birebir uyar.
- Tier değerleri her composition'da **tek bir yerde** (`function.k`) tanımlıdır.
- Her composition için `crossplane render` çıktısı örnekleştirilip
  `docs/examples-output/` altına kaydedilir (golden-file'ın bu fazdaki karşılığı;
  CI'da otomatik diff henüz yok — `render-examples.sh`'in elle çalıştırılması gerekiyor).

Gerekçe (neden KCL, neden Patch&Transform değil) → ADR-0001 Karar 2.4.

Durum: `tenant/` Faz 6'da yazıldı (manifestler + gerçek `crossplane render`
ile doğrulandı), henüz hiçbir cluster'a uygulanmadı.
