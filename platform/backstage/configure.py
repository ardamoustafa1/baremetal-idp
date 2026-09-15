#!/usr/bin/env python3
"""Materialize non-secret deployment values before committing GitOps manifests."""
import os,json,subprocess
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

# DÜZELTME (code review #11'in yan bulgusu — bu script'in KENDİSİ #11'in
# ASIL kök nedenlerinden biriydi): bu dosya ÖNCEDEN 05/06/07 .tpl→.yaml
# render'ını KENDİ, NAİF `str.replace()` mantığıyla yapıyordu —
# `render-app-manifests.sh`'in (SUBST_VARS whitelist'i, çözülmemiş
# değişken güvenlik ağı, `--verify` drift kontrolü İÇEREN) mantığından
# TAMAMEN BAĞIMSIZ, İKİNCİ bir render YOLU. İKİ AYRI mekanizmanın AYNI
# hedef dosyaları render etmesi, tam olarak bu OTURUMUN tekrar tekrar
# bulduğu "manuel ile GitOps'un SESSİZCE SAPMASI" hata sınıfıdır (bkz.
# Velero/Loki/Tempo — Faz 12k/code review #12) — burada İKİ RENDER
# YOLUNUN BİRBİRİNDEN sapması riski. `render-app-manifests.sh` artık
# TEK doğruluk kaynağı: bu script'in KENDİ zorunlu (`required`) listesi
# TENANT_REQUESTS_REPO_URL/PLATFORM_REPO_URL'i ZATEN garanti ettiği için
# `--require-tenant-requests` ile GÜVENLE çağrılabilir.
subprocess.run(
    [str(root.parent/'bootstrap/render-app-manifests.sh'),'--require-tenant-requests'],
    check=True,
    env={**os.environ,'PLATFORM_REPO_REVISION':os.environ.get('PLATFORM_REPO_REVISION','main')},
)
