#!/usr/bin/env python3
"""kind-chain e2e testi için: composition.yaml'ın gömülü KCL `source` bloğundan
belirli `items = [...]` girdilerini çıkarır (satırı KELİMESİ KELİMESİNE
eşleştirerek — KCL'i parse etmez, yalnızca metinsel bir satır filtresi
uygular). Yalnızca run.sh'in ürettiği GEÇİCİ bir kopya üzerinde çalışır;
repodaki gerçek composition.yaml dosyasını hiçbir zaman değiştirmez.

Kullanım:
    strip_unsupported_resources.py <girdi composition.yaml> <çıktı yolu> <kaynak-adı> [<kaynak-adı> ...]
"""
import sys


def main() -> None:
    src, dst, *names = sys.argv[1:]
    lines = open(src).readlines()
    # Satırın STRIP edilmiş hali tam olarak bir kaynak adına eşitse at
    # (KCL `items = [...]` listesindeki, her biri kendi satırında duran
    # kaynak referanslarını hedefler).
    kept = [line for line in lines if line.strip() not in names]
    open(dst, "w").writelines(kept)
    removed = len(lines) - len(kept)
    print(f"{removed} satır çıkarıldı ({', '.join(names)}) → {dst}")


if __name__ == "__main__":
    main()
