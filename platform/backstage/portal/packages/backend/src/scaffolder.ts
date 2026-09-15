import {
  createBackendModule,
  coreServices,
} from '@backstage/backend-plugin-api';
import {
  createTemplateAction,
  scaffolderActionsExtensionPoint,
} from '@backstage/plugin-scaffolder-node';
import { kube, claimBase } from './kube';
import {
  canAccessTenant,
  isAdmin,
  tenantNamespace,
  Tenant,
} from './tenantAccess';

export function authorizeRequest(
  operation: string,
  tenantRef: string | undefined,
  refs: string[],
  tenants: Tenant[],
) {
  if (operation === 'create-tenant') {
    if (!isAdmin(refs))
      throw new Error('Only platform administrators can create tenants');
    return;
  }
  if (operation !== 'request-postgres')
    throw new Error('Unknown platform operation');
  const matches = tenants.filter(t => tenantNamespace(t) === tenantRef);
  if (matches.length !== 1 || !canAccessTenant(refs, matches[0]))
    throw new Error('Not authorized for the requested tenant');
}

export default createBackendModule({
  pluginId: 'scaffolder',
  moduleId: 'tenant-authorization',
  register(reg) {
    reg.registerInit({
      deps: {
        actions: scaffolderActionsExtensionPoint,
        userInfo: coreServices.userInfo,
      },
      async init({ actions, userInfo }) {
        actions.addActions(
          createTemplateAction({
            id: 'platform:authorize',
            description:
              'Authorize the authenticated initiator before preparing a platform request.',
            schema: {
              input: {
                operation: z => z.enum(['create-tenant', 'request-postgres']),
                tenantRef: z => z.string().optional(),
              },
            },
            async handler(ctx) {
              const credentials = await ctx.getInitiatorCredentials();
              const { ownershipEntityRefs } = await userInfo.getUserInfo(
                credentials,
              );
              const tenants =
                ctx.input.operation === 'request-postgres'
                  ? (await kube(`${claimBase}/tenants`)).items
                  : [];
              authorizeRequest(
                ctx.input.operation,
                ctx.input.tenantRef,
                ownershipEntityRefs,
                tenants,
              );
            },
          }),
        );
      },
    });
  },
});
