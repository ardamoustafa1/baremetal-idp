# Architecture Decision Records (ADR)

Mimari kararların **gerekçesiyle birlikte** kaydı. Amaç, altı ay sonra
"bunu neden böyle yapmışız?" sorusunu cevaplayabilmektir.

## Format

Her ADR üç bölüm içerir:

- **Context** — hangi kısıtlar ve hangi problem bu kararı gerektirdi
- **Decision** — ne yapmaya karar verdik, **neden** ve **neden alternatifi değil**
- **Consequences** — bunun sonucunda ne kazandık, ne kaybettik, hangi yollar kapandı

## Kurallar

- Dosya adı: `NNNN-kisa-baslik.md`, 4 haneli artan sıra numarası.
- Bir ADR **değiştirilmez**; kararı değiştiren yeni bir ADR yazılır ve eskisinin
  durumu `Yerini aldı: ADR-NNNN` olarak işaretlenir.
- Reddedilen alternatifler **yazılır**. Değerin yarısı buradadır.
- Bedeller (trade-off) açıkça kabul edilir; "sorunsuz" diye bir karar yoktur.

## Kayıt

| # | Başlık | Durum | Tarih |
|---|---|---|---|
| [0001](0001-architecture.md) | Bare-metal çok-kiracılı IDP mimarisi | Kabul edildi | 2026-09-14 |
| 0002 | Tenant yalıtım modeli — namespace mı, sanal küme mi | Planlandı | — |
| 0003 | Veritabanı hizmet modeli ve yedekleme/geri yükleme SLO'su | Planlandı | — |
| 0004 | Ağ politikası varsayılanı (default-deny) ve egress kontrolü | Planlandı | — |
