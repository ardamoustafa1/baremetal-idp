import { useEffect, useState } from 'react';
import { useEntity } from '@backstage/plugin-catalog-react';
import { discoveryApiRef, fetchApiRef, useApi } from '@backstage/core-plugin-api';
import { InfoCard, Progress, ResponseErrorPanel } from '@backstage/core-components';
export function CrossplaneStatus() {
  const { entity } = useEntity();
  const discovery = useApi(discoveryApiRef); const fetchApi = useApi(fetchApiRef);
  const [data,setData] = useState<any>(); const [error,setError] = useState<Error>();
  const name = entity.metadata.annotations?.['platform.internal/claim-name'];
  const kind = entity.metadata.annotations?.['platform.internal/claim-kind'];
  useEffect(() => {
    let active = true;
    const load = async () => {
      if (!name || !kind) return;
      try {
        const base = await discovery.getBaseUrl('platform-crossplane');
        const response = await fetchApi.fetch(`${base}/${encodeURIComponent(kind)}/${encodeURIComponent(name)}`);
        if (!response.ok) throw new Error(`Crossplane: HTTP ${response.status}`);
        const result = await response.json(); if (active) { setData(result); setError(undefined); }
      } catch (e) { if (active) setError(e as Error); }
    };
    load(); const timer = setInterval(load, 15000);
    return () => { active=false; clearInterval(timer); };
  }, [name,kind,discovery,fetchApi]);
  if (!name) return <InfoCard title="Crossplane">Bu varlık bir Claim ile ilişkili değil.</InfoCard>;
  if (error) return <ResponseErrorPanel error={error} />;
  if (!data) return <Progress />;
  return <InfoCard title="Crossplane Claim / Composite">
    {['claim','composite'].map(type => <section key={type}><h3>{type}: {data[type]?.name ?? 'Bekleniyor'}</h3>
      <table><thead><tr><th>Condition</th><th>Status</th><th>Reason</th><th>Message</th></tr></thead><tbody>
        {data[type]?.conditions.map((c:any) => <tr key={c.type}><td>{c.type}</td><td>{c.status}</td><td>{c.reason}</td><td>{c.message}</td></tr>)}
      </tbody></table></section>)}
  </InfoCard>;
}
