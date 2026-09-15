#!/usr/bin/env python3
"""Read-only production gate. Missing connectivity/evidence is a failure, never a pass.
Usage: check-live.py --context NAME [--output /tmp/readiness.json]
No credentials or Kubernetes Secret values are read or included in the report.
"""
import argparse
import datetime as dt
import json
import subprocess
from pathlib import Path


def recent(timestamp, hours=26):
    if not timestamp:
        return False
    try:
        age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
        return dt.timedelta(0) <= age <= dt.timedelta(hours=hours)
    except (ValueError, TypeError):
        return False


def uncovered_pvcs(pvcs, pods, volume_backups, database_backups):
    """A declared annotation is not evidence: require a recent completed backup."""
    covered = set()
    pod_by_uid = {p['metadata']['uid']: p for p in pods}
    for backup in volume_backups:
        if backup.get('status', {}).get('phase') != 'Completed' or not recent(backup['status'].get('completionTimestamp')):
            continue
        pod = pod_by_uid.get(backup.get('spec', {}).get('pod', {}).get('uid'))
        if not pod:
            continue
        volume = backup['spec'].get('volume')
        for v in pod.get('spec', {}).get('volumes', []):
            if v['name'] == volume and 'persistentVolumeClaim' in v:
                covered.add((pod['metadata']['namespace'], v['persistentVolumeClaim']['claimName']))
    databases = {(b['metadata']['namespace'], b.get('spec', {}).get('cluster', {}).get('name'))
                 for b in database_backups if b.get('status', {}).get('phase') == 'completed'
                 and recent(b['status'].get('stoppedAt'))}
    missing = []
    for pvc in pvcs:
        if pvc.get('status', {}).get('phase') != 'Bound':
            continue
        meta = pvc['metadata']; key = (meta['namespace'], meta['name'])
        cluster = meta.get('labels', {}).get('cnpg.io/cluster')
        if key not in covered and (not cluster or (meta['namespace'], cluster) not in databases):
            missing.append('/'.join(key))
    return sorted(missing)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context', required=True)
    parser.add_argument('--output', default='/tmp/platform-readiness.json')
    parser.add_argument('--acceptance', help='JSON report containing reviewed staging acceptance evidence')
    args = parser.parse_args()
    checks = []
    def record(name, ok, detail):
        checks.append({'check':name, 'pass':bool(ok), 'detail':detail})
    def get(resource, *flags):
        p = subprocess.run(['kubectl', '--context', args.context, '--request-timeout=20s', 'get', resource, *flags, '-o', 'json'], capture_output=True, text=True, timeout=30)
        if p.returncode:
            raise RuntimeError(f'Unable to read {resource}; check connectivity and RBAC')
        return json.loads(p.stdout)
    try:
        dirty = subprocess.check_output(['git','status','--porcelain','--untracked-files=all','--','platform','.github','tenant-requests'], text=True)
        record('reviewed-revision', not dirty.strip(), 'Release evidence must refer to committed, unchanged source files')
        nodes = get('nodes')['items']
        record('nodes-ready', bool(nodes) and all(any(c['type']=='Ready' and c['status']=='True' for c in n.get('status',{}).get('conditions',[])) for n in nodes), f'{len(nodes)} nodes')
        locations = get('backupstoragelocations.velero.io', '-n','velero')['items']
        record('offsite-storage', any(b['metadata']['name']=='offsite' and b.get('status',{}).get('phase')=='Available' for b in locations), 'Offsite BackupStorageLocation must be Available')
        backups = get('backups.velero.io','-n','velero')['items']
        for location in ['default','offsite']:
            valid = [b for b in backups if b.get('spec',{}).get('storageLocation')==location and b.get('status',{}).get('phase')=='Completed' and recent(b['status'].get('completionTimestamp'))]
            record(f'backup-{location}', bool(valid), 'Completed backup within 26 hours required')
        agent = get('daemonset','node-agent','-n','velero').get('status',{})
        record('velero-node-agent', agent.get('desiredNumberScheduled',0)>0 and agent.get('numberReady')==agent.get('desiredNumberScheduled'), 'Node-agent must be ready on every scheduled node')
        missing = uncovered_pvcs(get('pvc','-A')['items'],get('pods','-A')['items'],get('podvolumebackups.velero.io','-n','velero')['items'],get('backups.postgresql.cnpg.io','-A')['items'])
        record('pvc-backup-coverage', not missing, {'uncovered':missing})
        restores = get('restores.velero.io','-n','velero')['items']
        record('restore-executed', any(r.get('status',{}).get('phase')=='Completed' and recent(r['status'].get('completionTimestamp'),168) for r in restores), 'Recent completed restore required; application data checks remain mandatory')
        apps = get('applications.argoproj.io','-n','argocd')['items']
        bad = [a['metadata']['name'] for a in apps if a.get('status',{}).get('sync',{}).get('status')!='Synced' or a.get('status',{}).get('health',{}).get('status')!='Healthy']
        record('gitops-health', bool(apps) and not bad, {'unhealthy':bad})
        # Separate real application acceptance from Kubernetes object health.
        evidence = json.loads(Path(args.acceptance).read_text()) if args.acceptance else {}
        revision = subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip()
        for scenario in ['oidc-four-users','postgres-offsite-pitr','vault-replacement-renewal','alert-delivery']:
            result = evidence.get('scenarios',{}).get(scenario,{})
            attachment = Path(args.acceptance).resolve().parent / result.get('evidenceFile','') if args.acceptance else None
            valid = (evidence.get('context') == args.context and evidence.get('revision') == revision
                     and result.get('passed') is True and recent(result.get('checkedAt'),168)
                     and bool(result.get('reviewedBy')) and attachment is not None
                     and attachment.is_file() and attachment.stat().st_size > 0)
            record(scenario, valid, 'Reviewed test evidence for this context/revision, no older than 7 days, is required')

    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        record('cluster-access', False, str(error))
    report={'context':args.context,'checkedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'ready':all(c['pass'] for c in checks),'checks':checks}
    Path(args.output).write_text(json.dumps(report,indent=2)+'\n')
    for c in checks:
        print(('PASS' if c['pass'] else 'FAIL') + ': ' + c['check'] + ' — ' + str(c['detail']))
    raise SystemExit(0 if report['ready'] else 1)

if __name__=='__main__':
    main()
