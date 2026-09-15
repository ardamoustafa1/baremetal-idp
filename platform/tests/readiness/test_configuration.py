import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
import yaml
import jsonschema
ROOT = Path(__file__).resolve().parents[3]
class Configuration(unittest.TestCase):
    def test_tenant_requires_group(self):
        schema=yaml.safe_load((ROOT/'platform/compositions/tenant/xrd.yaml').read_text())['spec']['versions'][0]['schema']['openAPIV3Schema']
        claim=yaml.safe_load((ROOT/'tenant-requests/tenants/acme-dev.yaml').read_text())
        jsonschema.validate(claim,schema)
        del claim['spec']['oidcGroup']
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(claim,schema)
    def test_trusted_certificate_requires_correct_server_name(self):
        openssl = '/opt/homebrew/bin/openssl' if Path('/opt/homebrew/bin/openssl').exists() else shutil.which('openssl')
        self.assertIsNotNone(openssl)
        with tempfile.TemporaryDirectory() as td:
            cert=str(Path(td)/'cert.pem');key=str(Path(td)/'key.pem')
            subprocess.run([openssl,'req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',key,'-out',cert,'-subj','/CN=vault-active.vault.svc.cluster.local','-addext','subjectAltName=DNS:vault-active.vault.svc.cluster.local'],check=True,capture_output=True)
            def verify(option, name):
                return subprocess.run([openssl,'verify','-CAfile',cert,option,name,cert],capture_output=True).returncode
            self.assertEqual(verify('-verify_hostname','vault-active.vault.svc.cluster.local'),0)
            self.assertNotEqual(verify('-verify_ip','127.0.0.1'),0)
    def test_bootstrap_and_raft_use_mounted_ca(self):
        overlay=yaml.safe_load((ROOT/'platform/pki/vault/values-tls.yaml').read_text())
        config=overlay['server']['ha']['raft']['config']
        self.assertEqual(config.count('leader_ca_cert_file = "/vault/userconfig/vault-ca/ca.crt"'),3)
        script=(ROOT/'platform/bootstrap/03-pki.sh').read_text()
        verified=[l for l in script.splitlines() if 'VAULT_CACERT=' in l and 'vault status' in l]
        self.assertEqual(len(verified),2)
        for line in verified:
            self.assertIn('VAULT_TLS_SERVER_NAME=vault-active.vault.svc.cluster.local',line)
            self.assertNotIn('VAULT_SKIP_VERIFY=true',line)
    def test_scaffolder_authorizes_before_any_side_effect(self):
        for path in (ROOT/'platform/backstage/templates').glob('*/template.yaml'):
            steps=yaml.safe_load(path.read_text())['spec']['steps']
            self.assertEqual(steps[0]['action'],'platform:authorize')
            self.assertEqual(steps[0]['input']['operation'],path.parent.name)
        config=yaml.safe_load((ROOT/'platform/backstage/app/app-config.yaml').read_text())
        self.assertNotIn('signIn',config['auth']['providers']['oidc']['production'])
        self.assertTrue(config['permission']['enabled'])
    def test_filesystem_backup_is_opt_in_and_snapshots_disabled(self):
        for name in ['values.yaml','values.yaml.tpl']:
            d=yaml.safe_load((ROOT/'platform/control-plane/velero'/name).read_text())
            self.assertTrue(d['deployNodeAgent'])
            self.assertFalse(d['configuration']['defaultVolumesToFsBackup'])
            self.assertFalse(d['schedules']['daily']['template']['snapshotVolumes'])
if __name__=='__main__': unittest.main()
