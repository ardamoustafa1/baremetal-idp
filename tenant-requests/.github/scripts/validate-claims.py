#!/usr/bin/env python3
"""Fail-closed Claim/XRD, real render and rendered-policy validation."""
import os, sys, subprocess, tempfile, json, re
from pathlib import Path
import yaml
import jsonschema
ROOT=Path(__file__).resolve().parents[2]
PLATFORM=Path(os.environ.get('PLATFORM_REPO_DIR',str(ROOT.parent)))/'platform'
report=Path(os.environ.get('REPORT_FILE','/tmp/validation-report.md'))
files=os.environ.get('CHANGED_FILES','').splitlines()
failed=False
seen=set()
rows=['| Claim | Sonuç |','|---|---|']
def run(args):
 p=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 if p.returncode: raise ValueError(p.stdout[-8000:])
 return p.stdout
for filename in files:
 if not filename: continue
 try:
  if not re.fullmatch(r'(clusters/[a-z0-9-]+/)?(tenants|postgresql)/[a-z0-9-]+\.ya?ml',filename): raise ValueError('ApplicationSet tarafından izlenmeyen path')
  path=ROOT/filename
  if not path.resolve().is_relative_to(ROOT): raise ValueError('Repo dışı path')
  if not path.exists(): continue
  docs=list(yaml.safe_load_all(path.read_text()))
  if len(docs)!=1 or not isinstance(docs[0],dict): raise ValueError('Dosyada tam bir Claim olmalı')
  claim=docs[0]; kind=claim.get('kind'); comp={'Tenant':'tenant','PostgreSQLInstance':'postgresql'}.get(kind)
  if not comp: raise ValueError('İzin verilmeyen kind')
  expected='tenants' if comp=='tenant' else 'postgresql'
  if path.parent.name!=expected: raise ValueError('Claim türü/path uyuşmuyor')
  if filename.startswith('clusters/') and Path(filename).parts[1] not in os.environ.get('ALLOWED_CLUSTERS','platform').split(','): raise ValueError('Bilinmeyen cluster')
  if claim.get('apiVersion')!='platform.internal/v1alpha1': raise ValueError('Yanlış apiVersion')
  if claim.get('metadata',{}).get('namespace')!='tenant-requests': raise ValueError('namespace tenant-requests olmalı')
  if not re.fullmatch(r'[a-z][a-z0-9-]{1,61}[a-z0-9]', claim.get('metadata',{}).get('name','')): raise ValueError('metadata.name DNS etiketi olmalı (3-63 karakter)')
  cluster=Path(filename).parts[1] if filename.startswith('clusters/') else 'platform'
  identity=(cluster,kind,claim['metadata']['name'])
  if identity in seen: raise ValueError('Aynı cluster/kind/name için birden fazla Claim dosyası')
  seen.add(identity)
  if set(claim)-{'apiVersion','kind','metadata','spec'}: raise ValueError('Claim üst alanı izinli değil')
  xrd=yaml.safe_load((PLATFORM/f'compositions/{comp}/xrd.yaml').read_text())
  schema=xrd['spec']['versions'][0]['schema']['openAPIV3Schema']
  schema['required']=['spec']; schema['properties']['spec']['additionalProperties']=False
  jsonschema.validate(claim,schema)
  spec=claim['spec']
  if comp=='tenant' and spec['environment']=='prod' and spec['quotaTier']=='small': raise ValueError('prod + small yasak (XRD CEL)')
  if comp=='postgresql' and spec['highAvailability'] and spec['size']=='small': raise ValueError('HA + small yasak (XRD CEL)')
  with tempfile.TemporaryDirectory() as td:
   work=Path(td); (work/'schema.json').write_text(json.dumps(schema))
   run(['kubeconform','-strict','-summary','-schema-location',str(work/'schema.json'),str(path)])
   claim['kind']=xrd['spec']['names']['kind'];claim['metadata']={'name':claim['metadata']['name']}
   (work/'xr.yaml').write_text(yaml.safe_dump(claim))
   rendered=run(['crossplane','render',str(work/'xr.yaml'),str(PLATFORM/f'compositions/{comp}/composition.yaml'),str(PLATFORM/f'compositions/{comp}/tests/functions.yaml')])
   resources=[]
   for obj in yaml.safe_load_all(rendered):
    if not obj or obj.get('kind') in [claim['kind'],'Result']: continue
    # provider-kubernetes Object wraps the actual admission resource.
    resources.append(obj.get('spec',{}).get('forProvider',{}).get('manifest',obj))
   if not resources: raise ValueError('Render boş kaynak üretti')
   (work/'resources.yaml').write_text(yaml.safe_dump_all(resources))
   for policy in ['07-restrict-certificate-issuer','08-require-pss-restricted']:
    run(['kyverno','apply',str(PLATFORM/f'policies/validation/{policy}.yaml'),'--resource',str(work/'resources.yaml')])
  rows.append(f'| `{filename}` | ✅ schema + render + policy |')
 except Exception as error:
  failed=True;rows.append(f'| `{filename}` | ❌ |\n\n```text\n{str(error)[:8000]}\n```\n')
report.write_text('\n'.join(rows)+'\n')
print(report.read_text());sys.exit(1 if failed else 0)
