# Rook-Ceph — 3 node test topolojisi sizing

ADR-0001 Consequences #4: yığındaki operasyonel olarak en ağır bileşen.
Buradaki değerler **test topolojisi** içindir; üretim kapasite planı ayrı yapılacak.

---

## Önerilen node profili (node başına)

| Kaynak | Minimum | Önerilen | Gerekçe |
|---|---|---|---|
| CPU | 4 vCPU | **8 vCPU** | OSD başına ~1 core; 2 OSD + MON + MGR + RGW + MDS ≈ 5 core, kalanı workload'a |
| RAM | 16 GB | **32 GB** | OSD başına 4 GB (BlueStore cache), MON 2 GB, RGW 2 GB, MDS 2 GB, + kubelet/sistem |
| Sistem diski | 100 GB SSD | **200 GB SSD** | `/var/lib/rook` MON verisi + konteyner imajları; **OSD diskinden ayrı olmalı** |
| OSD diski | 1 × 500 GB | **2 × 1 TB NVMe/SSD** | Node başına 2 OSD, toplam 6 OSD; HDD **önerilmez** (IOPS darboğazı) |
| Ağ | 1 GbE | **10 GbE** | Yeniden dengeleme (rebalance) 1 GbE'de saatler sürer |

**OSD diski ham olmalı:** partition tablosu yok, filesystem yok, LVM yok.
`lsblk` çıktısında `MOUNTPOINT` boş görünmeli. Rook, üzerinde imza bulunan
diski sessizce atlar — "OSD sayısı beklenenden az" arızasının en sık nedeni budur.

---

## Daemon yerleşimi (3 node)

| Daemon | Sayı | Yerleşim | Gerekçe |
|---|---|---|---|
| MON | 3 | Her node'da 1 | Quorum = 2/3. Bir node kaybında küme ayakta. `allowMultiplePerNode: false` — aynı node'da 2 MON sahte HA'dır. |
| MGR | 2 | 2 node | Aktif + standby. 3. replika fayda getirmez. |
| OSD | 6 | Node başına 2 | `deviceFilter` ile eşleşen her disk 1 OSD. |
| RGW | 2 | 2 node | Tek node kaybına dayanır; S3 API kesintisiz. |
| MDS | 1+1 | aktif + standby | CephFS (RWX) için. `activeStandby: true`. |

---

## Replikasyon: neden 3/2

| Ayar | Değer | Ne olur |
|---|---|---|
| `size` (replika) | **3** | Her nesne 3 farklı node'da (failureDomain: host) |
| `min_size` | **2** | 2 replika ayaktayken yazma devam eder |

**Bir node kaybında:** 2 replika kalır, `min_size: 2` sağlanır → küme
**yazılabilir** kalır, `HEALTH_WARN` verir (degraded), otomatik yeniden
dengelemeye başlar.

**İki node kaybında:** 1 replika kalır, `min_size` sağlanmaz → küme
**yazmayı durdurur** (okuma da pratikte durur). Bu **kasıtlıdır**: veri kaybetmek
yerine durmak doğru olandır.

**`min_size: 1` YAPMAYIN.** Split-brain senaryosunda iki taraf da yazmaya devam
eder ve birleşme sırasında veri kaybı kesindir. `requireSafeReplicaSize: true`
bunu ayrıca engeller.

### Kullanılabilir kapasite

```
Ham kapasite  = 6 OSD × 1 TB          = 6 TB
Replika 3     → 6 TB / 3              = 2 TB
Ceph full ratio (%85)                 ≈ 1.7 TB kullanılabilir
Bir node kaybını tolere etmek için    ≈ 1.1 TB üzerine çıkmayın
```

> **Kural:** %70 doluluğu aşınca kapasite ekleyin. %85'te Ceph yazmayı durdurur
> ve o noktadan sonra disk eklemek de zorlaşır (rebalance için yer gerekir).

---

## Bilinçli kapatılan ayarlar

| Ayar | Değer | Neden |
|---|---|---|
| `removeOSDsIfOutAndSafeToRemove` | `false` | 3 node'da bir node düşünce otomatik OSD çıkarma, kalan 2 node'u doldurabilir. Karar operatörün. |
| `useAllDevices` | `false` | Kör disk tüketimi. `deviceFilter` zorunlu. |
| `network.connections.encryption` | `false` | msgr2 şifreleme CPU maliyetli. Faz 4'te kapasite ölçüldükten sonra açılacak. |
| `preserveFilesystemOnDelete` | `true` | CephFilesystem CR'ı yanlışlıkla silinirse veri kalır. |
| `preservePoolsOnDelete` | `true` | Aynı gerekçe, obje havuzları için. |

---

## Doğrulama

```bash
# Küme sağlığı (toolbox gerekir)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df

# Toolbox kurulu değilse
helm upgrade rook-ceph rook-release/rook-ceph -n rook-ceph \
  --reuse-values --set toolbox.enabled=true

# StorageClass'lar
kubectl get storageclass

# Bucket'lar
kubectl -n rook-ceph get obc,cephobjectstore
```

**Beklenen `ceph status`:** `HEALTH_OK`, `mon: 3 daemons, quorum a,b,c`,
`osd: 6 osds: 6 up, 6 in`.

`HEALTH_WARN` + `too few PGs` görüyorsanız: `pg_autoscaler` modülü açık,
birkaç dakika içinde kendi kendine düzelir.
