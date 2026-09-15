import { createBackendPlugin, coreServices } from '@backstage/backend-plugin-api';
import { Router } from 'express';
import { kube, claimBase } from './kube';
export default createBackendPlugin({
  pluginId: 'platform-crossplane',
  register(reg) {
    reg.registerInit({ deps: { http: coreServices.httpRouter }, async init({ http }) {
      const router = Router();
      router.get('/:kind/:name', async (req, res, next) => {
        try {
          const plural = ({Tenant:'tenants', PostgreSQLInstance:'postgresqlinstances'} as Record<string,string>)[req.params.kind];
          if (!plural || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(req.params.name)) { res.status(400).end(); return; }
          const claim = await kube(`${claimBase}/${plural}/${req.params.name}`);
          const ref = claim.spec.resourceRef;
          const xrPlural = plural === 'tenants' ? 'xtenants' : 'xpostgresqlinstances';
          const composite = ref ? await kube(`/apis/platform.internal/v1alpha1/${xrPlural}/${encodeURIComponent(ref.name)}`) : null;
          res.json({claim:{name:claim.metadata.name, conditions:claim.status?.conditions ?? []}, composite:composite ? {name:composite.metadata.name, conditions:composite.status?.conditions ?? []} : null});
        } catch (error) { next(error); }
      });
      // Default Backstage backend authentication remains required.
      http.use(router);
    }});
  },
});
