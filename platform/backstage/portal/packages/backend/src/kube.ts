import https from 'node:https';
import { readFileSync } from 'node:fs';
// Read projected credentials for every request: Kubernetes rotates these files.
export async function kube(path: string): Promise<any> {
  const base = '/var/run/secrets/kubernetes.io/serviceaccount/';
  return new Promise((resolve, reject) => {
    const request = https.get(`https://kubernetes.default.svc${path}`, {
      ca: readFileSync(`${base}ca.crt`),
      headers: { Authorization: `Bearer ${readFileSync(`${base}token`, 'utf8').trim()}` },
      timeout: 15000,
    }, response => {
      let data = '';
      response.on('data', chunk => { data += chunk; });
      response.on('end', () => {
        if (response.statusCode !== 200) { reject(new Error(`Kubernetes ${response.statusCode}: ${path}`)); return; }
        try { resolve(JSON.parse(data)); } catch (error) { reject(error); }
      });
    });
    request.on('timeout', () => request.destroy(new Error('Kubernetes timeout')));
    request.on('error', reject);
  });
}
export const claimBase = '/apis/platform.internal/v1alpha1/namespaces/tenant-requests';
