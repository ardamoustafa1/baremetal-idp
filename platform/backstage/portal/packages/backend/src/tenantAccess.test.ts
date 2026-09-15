import { identityClaims, canAccessTenant, ADMIN_GROUP } from './tenantAccess';
const acme = {
  spec: { teamName: 'acme', environment: 'prod', oidcGroup: 'tenant-acme' },
};
const other = {
  spec: { teamName: 'other', environment: 'prod', oidcGroup: 'tenant-other' },
};
it('maps exact verified OIDC groups and isolates tenants', () => {
  const claims = identityClaims({ sub: '42', groups: ['tenant-acme'] }, [
    acme,
    other,
  ]);
  expect(canAccessTenant(claims.ent, acme)).toBe(true);
  expect(canAccessTenant(claims.ent, other)).toBe(false);
  expect(claims.ent).not.toContain(ADMIN_GROUP);
});
it('does not elevate similarly named groups or catalog membership', () => {
  expect(() =>
    identityClaims(
      { sub: '42', groups: ['platform-team', '/platform-admins'] },
      [acme],
    ),
  ).toThrow();
  expect(
    identityClaims({ sub: '42', groups: ['platform-admins'] }, [acme]).ent,
  ).toContain(ADMIN_GROUP);
});
it('fails closed when membership is removed or the mapper is missing', () => {
  for (const groups of [undefined, [], 'tenant-acme', [1]]) {
    expect(() => identityClaims({ sub: '42', groups }, [acme])).toThrow();
  }
});
it('uses immutable subject identity rather than mutable email', () => {
  expect(
    identityClaims(
      { sub: '42', email: 'one@company.test', groups: ['tenant-acme'] },
      [acme],
    ).sub,
  ).toBe(
    identityClaims(
      { sub: '42', email: 'two@company.test', groups: ['tenant-acme'] },
      [acme],
    ).sub,
  );
});
