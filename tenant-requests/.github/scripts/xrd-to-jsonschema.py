#!/usr/bin/env python3
"""
XRD'lerin openAPIV3Schema'sını kubeconform'un yerel şema konumu şablonuyla
({{.ResourceKind}}_{{.ResourceAPIVersion}}.json) eşleşen bağımsız JSON
Schema dosyalarına dönüştürür.

NEDEN CI-ZAMANINDA ÜRETİLİYOR, COMMIT EDİLMİYOR: platform reposundaki
xrd.yaml'lar TEK doğruluk kaynağıdır. Statik bir kopya commit etmek,
XRD değiştiğinde SESSİZCE eskiyen bir ikinci kaynak yaratırdı — Faz 6'nın
composition.yaml/function.k senkron sorununun aynısı. Bu script her CI
koşumunda TAZE üretir, drift'e izin vermez.

Hem XRD'nin CLAIM şeması (kubectl create -f ile kullanıcının yazdığı,
`Tenant`/`PostgreSQLInstance`) hem COMPOSITE şeması (`XTenant`/
`XPostgreSQLInstance`) için birer dosya üretilir — ikisi de AYNI
openAPIV3Schema'yı paylaşır (Crossplane, claim spec'ini XR'a birebir
kopyalar).
"""
import json
import sys
import yaml
from pathlib import Path

def convert(xrd_path: Path, out_dir: Path) -> None:
    with open(xrd_path) as f:
        xrd = yaml.safe_load(f)

    spec = xrd["spec"]
    group = spec["group"]
    composite_kind = spec["names"]["kind"]
    claim_kind = spec["claimNames"]["kind"]

    version = spec["versions"][0]
    version_name = version["name"]
    inner_schema = version["schema"]["openAPIV3Schema"]

    document_schema = {
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "properties": {
            "apiVersion": {"type": "string"},
            "kind": {"type": "string"},
            "metadata": {"type": "object"},
            **inner_schema.get("properties", {}),
        },
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    for kind in (composite_kind, claim_kind):
        # kubeconform dosya adını KÜÇÜK HARFE çevirerek arar — büyük/küçük
        # harf duyarlı dosya sistemlerinde (Linux CI runner'ları) bu
        # ZORUNLUDUR; macOS'ta fark edilmez, bu yüzden bilinçli olarak
        # tamamen küçük harfle yazılıyor.
        out_path = out_dir / f"{kind.lower()}_{version_name}.json"
        out_path.write_text(json.dumps(document_schema, indent=2))
        print(f"  {xrd_path} -> {out_path}  (group={group})")

def main() -> int:
    if len(sys.argv) < 3:
        print("Kullanım: xrd-to-jsonschema.py <out_dir> <xrd.yaml> [<xrd.yaml> ...]", file=sys.stderr)
        return 1

    out_dir = Path(sys.argv[1])
    for xrd_arg in sys.argv[2:]:
        convert(Path(xrd_arg), out_dir)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
