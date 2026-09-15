import { createHash } from 'node:crypto';

export const ADMIN_GROUP = 'group:default/platform-team';
export type Tenant = {
  spec?: { teamName?: string; environment?: string; oidcGroup?: string };
};
export const ownerRef = (tenant: Tenant) =>
  `group:default/team-${tenant.spec?.teamName}`;
export const tenantNamespace = (tenant: Tenant) =>
  `tenant-${tenant.spec?.teamName}-${tenant.spec?.environment}`;
export const isAdmin = (refs: readonly string[]) => refs.includes(ADMIN_GROUP);
export function canAccessTenant(refs: readonly string[], tenant: Tenant) {
  return (
    isAdmin(refs) ||
    (!!tenant.spec?.teamName && refs.includes(ownerRef(tenant)))
  );
}

// Only authenticated OIDC userinfo is passed here. Catalog edits and submitted
// form fields never grant group membership. Missing group claims fail closed.
export function identityClaims(
  userinfo: Record<string, unknown>,
  tenants: Tenant[],
) {
  if (
    typeof userinfo.sub !== 'string' ||
    !userinfo.sub ||
    !Array.isArray(userinfo.groups) ||
    !userinfo.groups.every(g => typeof g === 'string')
  ) {
    throw new Error('OIDC sub and groups claims are required');
  }
  const groups = new Set(userinfo.groups as string[]);
  const sub = `user:default/oidc-${createHash('sha256')
    .update(userinfo.sub)
    .digest('hex')}`;
  const refs = new Set([sub]);
  if (groups.has('platform-admins')) refs.add(ADMIN_GROUP);
  for (const tenant of tenants) {
    if (
      tenant.spec?.teamName &&
      tenant.spec.oidcGroup &&
      groups.has(tenant.spec.oidcGroup)
    )
      refs.add(ownerRef(tenant));
  }
  if (refs.size === 1)
    throw new Error('No authorized platform group membership');
  return { sub, ent: [...refs] };
}
