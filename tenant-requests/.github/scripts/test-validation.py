#!/usr/bin/env python3
"""Real-tool regression: invalid schema, CEL, malformed YAML and policy denial."""
import os,subprocess,tempfile
from pathlib import Path
import yaml
root=Path(__file__).resolve().parents[2]
platform=Path(os.environ.get('PLATFORM_REPO_DIR',str(root.parent)))
base=yaml.safe_load((root/'tenants/acme-dev.yaml').read_text())
cases=[('valid',{},True),('missing-oidc-group',{},False),('invalid-tier',{'quotaTier':'gigantic'},False),('invalid-prod',{'environment':'prod'},False),('unknown-field',{'typo':True},False)]
for name,patch,expected in cases:
 doc={**base,'spec':{**base['spec'],**patch}}
 if name=='missing-oidc-group': doc['spec'].pop('oidcGroup',None)
 with tempfile.NamedTemporaryFile(mode='w',suffix='.yaml',prefix='regression-',dir=root/'tenants',delete=False) as f:
  yaml.safe_dump(doc,f);path=Path(f.name)
 try:
  result=subprocess.run(['bash',str(root/'.github/scripts/validate-claims.sh')],env={**os.environ,'PLATFORM_REPO_DIR':str(platform),'CHANGED_FILES':str(path.relative_to(root))},capture_output=True,text=True)
  assert (result.returncode==0)==expected,result.stdout+result.stderr
  print(f'PASS {name}: exit={result.returncode}')
 finally:path.unlink()
with tempfile.TemporaryDirectory() as td:
 p=Path(td)/'bad-namespace.yaml';p.write_text('apiVersion: v1\nkind: Namespace\nmetadata:\n  name: tenant-bad-dev\n  labels:\n    platform.internal/tenant: bad\n    pod-security.kubernetes.io/enforce: privileged\n')
 result=subprocess.run(['kyverno','apply',str(platform/'platform/policies/validation/08-require-pss-restricted.yaml'),'--resource',str(p)],capture_output=True,text=True)
 assert result.returncode!=0,result.stdout
 print('PASS policy denial: exit='+str(result.returncode))
