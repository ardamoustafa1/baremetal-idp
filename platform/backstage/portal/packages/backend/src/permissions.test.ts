import { TenantPermissionPolicy } from './permissions';
import {
  AuthorizeResult,
  createPermission,
} from '@backstage/plugin-permission-common';
const policy = new TenantPermissionPolicy();
const user = {
  info: {
    userEntityRef: 'user:default/alice',
    ownershipEntityRefs: ['group:default/team-acme'],
  },
} as any;
const request = (name: string, resourceType?: string) => ({
  permission: createPermission({
    name,
    attributes: {},
    ...(resourceType ? { resourceType } : {}),
  }),
});
it('denies unauthenticated callers, catalog writes, proxy access and unknown permissions', async () => {
  expect((await policy.handle(request('catalog.entity.read'))).result).toBe(
    AuthorizeResult.DENY,
  );
  for (const name of [
    'catalog.entity.create',
    'catalog.entity.delete',
    'kubernetes.proxy',
    'scaffolder.template.management',
    'new.plugin.write',
  ]) {
    expect((await policy.handle(request(name), user)).result).toBe(
      AuthorizeResult.DENY,
    );
  }
});
it('requires ownership for catalog data and task history', async () => {
  const catalog = await policy.handle(
    request('catalog.entity.read', 'catalog-entity'),
    user,
  );
  expect(catalog.result).toBe(AuthorizeResult.CONDITIONAL);
  expect(JSON.stringify(catalog)).toContain('group:default/team-acme');
  expect(JSON.stringify(catalog)).not.toContain('group:default/team-other');
  const task = await policy.handle(
    request('scaffolder.task.read', 'scaffolder-task'),
    user,
  );
  expect(task.result).toBe(AuthorizeResult.CONDITIONAL);
  expect(JSON.stringify(task)).toContain('user:default/alice');
});
it('allows platform administrators explicitly', async () => {
  expect(
    (
      await policy.handle(request('catalog.entity.create'), {
        info: {
          ...user.info,
          ownershipEntityRefs: ['group:default/platform-team'],
        },
      } as any)
    ).result,
  ).toBe(AuthorizeResult.ALLOW);
});
