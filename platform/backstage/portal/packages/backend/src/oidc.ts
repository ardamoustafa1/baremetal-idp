import { createBackendModule } from '@backstage/backend-plugin-api';
import {
  authProvidersExtensionPoint,
  createOAuthProviderFactory,
} from '@backstage/plugin-auth-node';
import { oidcAuthenticator } from '@backstage/plugin-auth-backend-module-oidc-provider';
import { kube, claimBase } from './kube';
import { identityClaims } from './tenantAccess';

export default createBackendModule({
  pluginId: 'auth',
  moduleId: 'platform-oidc',
  register(reg) {
    reg.registerInit({
      deps: { providers: authProvidersExtensionPoint },
      async init({ providers }) {
        providers.registerProvider({
          providerId: 'oidc',
          factory: createOAuthProviderFactory({
            authenticator: oidcAuthenticator,
            async signInResolver(info, ctx) {
              const tenants = await kube(`${claimBase}/tenants`);
              return ctx.issueToken({
                claims: identityClaims(
                  info.result.fullProfile.userinfo,
                  tenants.items,
                ),
              });
            },
          }),
        });
      },
    });
  },
});
