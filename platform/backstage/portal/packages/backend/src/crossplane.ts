import {
  createBackendPlugin,
  coreServices,
} from '@backstage/backend-plugin-api';
import { Router } from 'express';
import { kube, claimBase } from './kube';

import { ADMIN_GROUP } from './tenantAccess';

async function resolveOwnerGroup(
  kind: string,
  claim: any,
): Promise<string | undefined> {
  if (kind === 'Tenant') {
    const teamName = claim.spec?.teamName;
    return teamName ? `team-${teamName}` : undefined;
  }
  // PostgreSQLInstance'ın kendi teamName'i yok — sahipliği `tenantRef`
  // (tenant'ın namespace'i, örn. "tenant-acme-dev") üzerinden DOLAYLI.
  // O namespace'i üreten Tenant claim'ini bulup ONUN teamName'ini kullan.
  const tenantRef: string | undefined = claim.spec?.tenantRef;
  if (!tenantRef) return undefined;
  const list = await kube(`${claimBase}/tenants`);
  const owner = (list.items ?? []).find(
    (t: any) =>
      `tenant-${t.spec?.teamName}-${t.spec?.environment}` === tenantRef,
  );
  return owner?.spec?.teamName ? `team-${owner.spec.teamName}` : undefined;
}

export default createBackendPlugin({
  pluginId: 'platform-crossplane',
  register(reg) {
    reg.registerInit({
      deps: {
        http: coreServices.httpRouter,
        httpAuth: coreServices.httpAuth,
        userInfo: coreServices.userInfo,
      },
      async init({ http, httpAuth, userInfo }) {
        const router = Router();
        router.get('/:kind/:name', async (req, res, next) => {
          try {
            const plural = (
              {
                Tenant: 'tenants',
                PostgreSQLInstance: 'postgresqlinstances',
              } as Record<string, string>
            )[req.params.kind];
            if (!plural || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(req.params.name)) {
              res.status(400).end();
              return;
            }
            const credentials = await httpAuth.credentials(req, {
              allow: ['user'],
            });
            const { ownershipEntityRefs = [] } = await userInfo.getUserInfo(
              credentials,
            );
            const claim = await kube(
              `${claimBase}/${plural}/${req.params.name}`,
            );
            const ownerGroup = await resolveOwnerGroup(req.params.kind, claim);
            const ownerGroupRef = ownerGroup
              ? `group:default/${ownerGroup}`
              : undefined;
            const isOwner =
              !!ownerGroupRef && ownershipEntityRefs.includes(ownerGroupRef);
            const isPlatformAdmin = ownershipEntityRefs.includes(ADMIN_GROUP);
            if (!isOwner && !isPlatformAdmin) {
              res
                .status(403)
                .json({ error: 'Bu tenant kaynağına erişim yetkiniz yok.' });
              return;
            }

            const ref = claim.spec.resourceRef;
            const xrPlural =
              plural === 'tenants' ? 'xtenants' : 'xpostgresqlinstances';
            const composite = ref
              ? await kube(
                  `/apis/platform.internal/v1alpha1/${xrPlural}/${encodeURIComponent(
                    ref.name,
                  )}`,
                )
              : null;
            res.json({
              claim: {
                name: claim.metadata.name,
                conditions: claim.status?.conditions ?? [],
              },
              composite: composite
                ? {
                    name: composite.metadata.name,
                    conditions: composite.status?.conditions ?? [],
                  }
                : null,
            });
          } catch (error) {
            next(error);
          }
        });
        // Default Backstage backend authentication remains required; ownership
        // is additionally enforced per-request above.
        http.use(router);
      },
    });
  },
});
