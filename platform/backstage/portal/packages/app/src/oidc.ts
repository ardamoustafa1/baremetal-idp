import { createApiRef, OpenIdConnectApi, ProfileInfoApi, BackstageIdentityApi, SessionApi } from '@backstage/core-plugin-api';
export const oauth2ApiRef = createApiRef<OpenIdConnectApi & ProfileInfoApi & BackstageIdentityApi & SessionApi>({id:'auth.oidc'});
