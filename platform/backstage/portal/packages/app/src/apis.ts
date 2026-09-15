import { OAuth2 } from '@backstage/core-app-api';
import { oauth2ApiRef } from './oidc';
import { oauthRequestApiRef } from '@backstage/core-plugin-api';
import {
  ScmIntegrationsApi,
  scmIntegrationsApiRef,
  ScmAuth,
} from '@backstage/integration-react';
import {
  AnyApiFactory,
  configApiRef,
  createApiFactory,
  discoveryApiRef,
  errorApiRef,
  fetchApiRef,
  identityApiRef,
  storageApiRef,
} from '@backstage/core-plugin-api';
import { UserSettingsStorage } from '@backstage/plugin-user-settings';
import { signalApiRef } from '@backstage/plugin-signals-react';

export const apis: AnyApiFactory[] = [
  createApiFactory({
    api: oauth2ApiRef,
    deps: { discoveryApi: discoveryApiRef, oauthRequestApi: oauthRequestApiRef, configApi: configApiRef },
    factory: ({ discoveryApi, oauthRequestApi, configApi }) => OAuth2.create({
      discoveryApi, oauthRequestApi, provider: { id: 'oidc', title: 'Keycloak', icon: () => null },
      environment: configApi.getString('auth.environment'), defaultScopes: ['openid', 'profile', 'email'],
    }),
  }),
  createApiFactory({
    api: scmIntegrationsApiRef,
    deps: { configApi: configApiRef },
    factory: ({ configApi }) => ScmIntegrationsApi.fromConfig(configApi),
  }),
  createApiFactory({
    api: storageApiRef,
    deps: {
      discoveryApi: discoveryApiRef,
      errorApi: errorApiRef,
      fetchApi: fetchApiRef,
      identityApi: identityApiRef,
      signalApi: signalApiRef,
    },
    factory: deps => UserSettingsStorage.create(deps),
  }),
  ScmAuth.createDefaultApiFactory(),
];
