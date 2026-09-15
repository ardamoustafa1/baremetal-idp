import {
  createBackendModule,
  coreServices,
} from '@backstage/backend-plugin-api';
import { catalogProcessingExtensionPoint } from '@backstage/plugin-catalog-node/alpha';
import {
  EntityProvider,
  EntityProviderConnection,
} from '@backstage/plugin-catalog-node';
import { Entity } from '@backstage/catalog-model';
import { parse } from 'yaml';
import { kube, claimBase } from './kube';
import { ownerRef, tenantNamespace } from './tenantAccess';

export class PlatformProvider implements EntityProvider {
  private connection?: EntityProviderConnection;
  getProviderName() {
    return 'platform-ready-resources';
  }
  async connect(connection: EntityProviderConnection) {
    this.connection = connection;
  }
  async refresh() {
    const [tenants, databases, maps] = await Promise.all([
      kube(`${claimBase}/tenants`),
      kube(`${claimBase}/postgresqlinstances`),
      kube(
        '/api/v1/configmaps?labelSelector=backstage.io%2Fcatalog-info%3Dtrue',
      ),
    ]);
    const entities: Entity[] = [];
    const teams = new Set<string>(
      tenants.items.map((t: any) => t.spec?.teamName).filter(Boolean),
    );
    for (const team of teams) {
      entities.push({
        apiVersion: 'backstage.io/v1alpha1',
        kind: 'Group',
        metadata: { name: `team-${team}` },
        spec: { type: 'team', children: [] },
      });
    }
    for (const [kind, claims] of [
      ['Tenant', tenants.items],
      ['PostgreSQLInstance', databases.items],
    ] as const) {
      for (const claim of claims) {
        if (
          !claim.status?.conditions?.some(
            (c: any) => c.type === 'Ready' && c.status === 'True',
          )
        )
          continue;
        const ns =
          kind === 'Tenant'
            ? `tenant-${claim.spec.teamName}-${claim.spec.environment}`
            : claim.spec.tenantRef;
        const name =
          kind === 'Tenant'
            ? 'catalog-info'
            : `${claim.metadata.name}-catalog-info`;
        const cm = maps.items.find(
          (m: any) => m.metadata.namespace === ns && m.metadata.name === name,
        );
        if (!cm?.data?.['catalog-info.yaml']) continue;
        const source = parse(cm.data['catalog-info.yaml']) as Entity;
        const entity: Entity = {
          apiVersion: source.apiVersion,
          kind: source.kind,
          metadata: { name: source.metadata?.name },
          spec: {
            type: kind === 'Tenant' ? 'tenant' : 'database',
            lifecycle: 'production',
          },
        };
        const expectedName =
          kind === 'Tenant' ? ns : `postgres-${claim.metadata.name}`;
        if (
          entity.apiVersion !== 'backstage.io/v1alpha1' ||
          entity.kind !== 'Component' ||
          entity.metadata?.name !== expectedName
        ) {
          throw new Error(
            `Invalid catalog-info for ${kind}/${claim.metadata.name}`,
          );
        }
        const owners = tenants.items.filter(
          (t: any) => tenantNamespace(t) === ns,
        );
        if (owners.length !== 1 || !owners[0].spec?.teamName)
          throw new Error(`Ambiguous tenant owner: ${ns}`);
        entity.spec = { ...entity.spec, owner: ownerRef(owners[0]) };
        entity.metadata.annotations = {
          'backstage.io/kubernetes-namespace': ns,
          'backstage.io/kubernetes-label-selector':
            kind === 'Tenant'
              ? '!backstage.io/exclude'
              : `cnpg.io/cluster=${claim.metadata.name}`,
          'platform.internal/claim-name': claim.metadata.name,
          'platform.internal/claim-kind': kind,
          'backstage.io/managed-by-location': `url:https://kubernetes.default.svc${claimBase}/${
            kind === 'Tenant' ? 'tenants' : 'postgresqlinstances'
          }/${claim.metadata.name}`,
          'backstage.io/managed-by-origin-location':
            'url:https://kubernetes.default.svc',
        };
        entities.push(entity);
      }
    }
    // Never publish a partial snapshot on an API failure. Full mutation also removes deleted claims.
    await this.connection?.applyMutation({
      type: 'full',
      entities: entities.map(entity => ({
        entity,
        locationKey: this.getProviderName(),
      })),
    });
  }
}
export default createBackendModule({
  pluginId: 'catalog',
  moduleId: 'platform-ready-resources',
  register(reg) {
    reg.registerInit({
      deps: {
        catalog: catalogProcessingExtensionPoint,
        scheduler: coreServices.scheduler,
        config: coreServices.rootConfig,
      },
      async init({ catalog, scheduler, config }) {
        if (!config.getOptionalBoolean('platformCatalog.enabled')) return;
        const provider = new PlatformProvider();
        catalog.addEntityProvider(provider);
        await scheduler.scheduleTask({
          id: provider.getProviderName(),
          frequency: { seconds: 60 },
          timeout: { seconds: 45 },
          fn: () => provider.refresh(),
        });
      },
    });
  },
});
