import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  AuthorizeResult,
  isResourcePermission,
} from '@backstage/plugin-permission-common';
import {
  PermissionPolicy,
  PolicyQuery,
  PolicyQueryUser,
} from '@backstage/plugin-permission-node';
import { policyExtensionPoint } from '@backstage/plugin-permission-node/alpha';
import {
  catalogConditions,
  createCatalogConditionalDecision,
} from '@backstage/plugin-catalog-backend/alpha';
import {
  createScaffolderTaskConditionalDecision,
  scaffolderTaskConditions,
  createScaffolderActionConditionalDecision,
  scaffolderActionConditions,
} from '@backstage/plugin-scaffolder-backend/alpha';
import { isAdmin } from './tenantAccess';

export class TenantPermissionPolicy implements PermissionPolicy {
  async handle(request: PolicyQuery, user?: PolicyQueryUser) {
    if (!user) return { result: AuthorizeResult.DENY } as const;
    const refs = user.info.ownershipEntityRefs;
    if (isAdmin(refs)) return { result: AuthorizeResult.ALLOW } as const;
    const permission = request.permission;
    if (
      permission.name === 'catalog.entity.read' &&
      isResourcePermission(permission, 'catalog-entity')
    ) {
      return createCatalogConditionalDecision(permission, {
        anyOf: [
          catalogConditions.isEntityOwner({ claims: refs }),
          {
            allOf: [
              catalogConditions.isEntityKind({ kinds: ['Template'] }),
              catalogConditions.hasMetadata({
                key: 'name',
                value: 'request-postgres',
              }),
            ],
          },
        ],
      });
    }
    if (
      isResourcePermission(permission, 'scaffolder-task') &&
      ['scaffolder.task.read', 'scaffolder.task.cancel'].includes(
        permission.name,
      )
    ) {
      return createScaffolderTaskConditionalDecision(
        permission,
        scaffolderTaskConditions.isTaskOwner({
          createdBy: [user.info.userEntityRef],
        }),
      );
    }
    if (isResourcePermission(permission, 'scaffolder-action')) {
      return createScaffolderActionConditionalDecision(permission, {
        anyOf: [
          scaffolderActionConditions.hasActionId({
            actionId: 'platform:authorize',
          }),
          scaffolderActionConditions.hasActionId({
            actionId: 'fetch:template',
          }),
          scaffolderActionConditions.hasActionId({
            actionId: 'publish:github:pull-request',
          }),
        ],
      });
    }
    if (
      [
        'scaffolder.task.create',
        'scaffolder.template.parameter.read',
        'scaffolder.template.step.read',
        'kubernetes.resources.read',
        'kubernetes.clusters.read',
      ].includes(permission.name)
    ) {
      return { result: AuthorizeResult.ALLOW } as const;
    }
    // Catalog mutation, arbitrary Kubernetes proxy access, template editor,
    // and new plugin permissions require an explicit grant.
    return { result: AuthorizeResult.DENY } as const;
  }
}
export default createBackendModule({
  pluginId: 'permission',
  moduleId: 'tenant-policy',
  register(reg) {
    reg.registerInit({
      deps: { policy: policyExtensionPoint },
      async init({ policy }) {
        policy.setPolicy(new TenantPermissionPolicy());
      },
    });
  },
});
