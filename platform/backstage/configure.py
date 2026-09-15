#!/usr/bin/env python3
"""Materialize non-secret deployment values before committing GitOps manifests."""
import os,json
from pathlib import Path
import yaml
root=Path(__file__).resolve().parent
required=['PLATFORM_REPO_URL','PLATFORM_BASE_DOMAIN','KEYCLOAK_HOSTNAME','TENANT_REQUESTS_REPO_URL','BACKSTAGE_IMAGE_REGISTRY','BACKSTAGE_IMAGE_TAG','BACKSTAGE_USER_EMAIL']
for key in required:
 if not os.environ.get(key):raise SystemExit(f'{key} zorunlu (sır içermez)')
env={k:os.environ[k] for k in ['PLATFORM_BASE_DOMAIN','KEYCLOAK_HOSTNAME']};env['KEYCLOAK_REALM']='platform'
(root/'app/resources/environment.yaml').write_text(yaml.safe_dump({'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'backstage-environment','namespace':'backstage'},'data':env},sort_keys=False))
(root/'app/resources/config.yaml').write_text(yaml.safe_dump({'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'backstage-app-config','namespace':'backstage'},'data':{'app-config.yaml':(root/'app/app-config.yaml').read_text()}},sort_keys=False))
p=root/'app/values.yaml';d=yaml.safe_load(p.read_text());d['backstage']['image'].update(registry=os.environ['BACKSTAGE_IMAGE_REGISTRY'],tag=os.environ['BACKSTAGE_IMAGE_TAG']);p.write_text(yaml.safe_dump(d,sort_keys=False))
repo=os.environ['TENANT_REQUESTS_REPO_URL'].removesuffix('.git').removeprefix('https://github.com/');owner,name=repo.split('/')
for p in (root/'templates').glob('*/template.yaml'):
 d=yaml.safe_load(p.read_text());d['spec']['steps'][1]['input']['repoUrl']=f'github.com?owner={owner}&repo={name}'
 params=d['spec']['parameters'][0];params['required']=[s for s in params['required'] if s!='repoUrl'];params['properties'].pop('repoUrl',None)
 p.write_text(yaml.safe_dump(d,sort_keys=False,allow_unicode=True))
# Email matching is explicit and fails closed for users absent from the catalog.
p=root/'catalog/users.yaml';p.write_text(yaml.safe_dump({'apiVersion':'backstage.io/v1alpha1','kind':'User','metadata':{'name':'platform-operator'},'spec':{'profile':{'email':os.environ['BACKSTAGE_USER_EMAIL']},'memberOf':['platform-team']}},sort_keys=False))
# Reconfigure the already-imported realm through Admin API on existing clusters;
# realm import alone does not update existing realms.
print('GitOps config üretildi. Değişiklikleri inceleyip commit edin; image bu dosyalardan build edilir.')

# ArgoCD directory sources read .yaml/.yml/.json, not .tpl. Render concrete files.
for stem in ['05-tenant-requests-project','06-tenant-requests-appset','07-backstage']:
    folder=root.parent/'control-plane/apps'
    text=(folder/f'{stem}.yaml.tpl').read_text()
    for key in ['PLATFORM_REPO_URL','PLATFORM_REPO_REVISION','TENANT_REQUESTS_REPO_URL']:
        text=text.replace('${'+key+'}',os.environ.get(key,'main'))
    (folder/f'{stem}.yaml').write_text(text)
