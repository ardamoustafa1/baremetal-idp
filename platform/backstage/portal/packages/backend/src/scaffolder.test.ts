import { authorizeRequest } from './scaffolder';
const tenants = [
  { spec: { teamName: 'acme', environment: 'dev' } },
  { spec: { teamName: 'other', environment: 'prod' } },
];
const refs = ['group:default/team-acme'];
it('accepts own tenant and rejects forged, missing and ambiguous tenant targets', () => {
  expect(() =>
    authorizeRequest('request-postgres', 'tenant-acme-dev', refs, tenants),
  ).not.toThrow();
  for (const target of ['tenant-other-prod', 'tenant-missing-dev', undefined]) {
    expect(() =>
      authorizeRequest('request-postgres', target, refs, tenants),
    ).toThrow();
  }
  expect(() =>
    authorizeRequest('request-postgres', 'tenant-acme-dev', refs, [
      ...tenants,
      tenants[0],
    ]),
  ).toThrow();
});
it('reserves tenant creation for administrators and rejects unknown operations', () => {
  expect(() =>
    authorizeRequest('create-tenant', undefined, refs, tenants),
  ).toThrow();
  expect(() =>
    authorizeRequest(
      'create-tenant',
      undefined,
      ['group:default/platform-team'],
      tenants,
    ),
  ).not.toThrow();
  expect(() => authorizeRequest('unknown', undefined, refs, tenants)).toThrow();
});
