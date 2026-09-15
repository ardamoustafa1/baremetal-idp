import { PlatformProvider } from './platformCatalog';
import { kube } from './kube';
jest.mock('./kube', () => ({kube: jest.fn(), claimBase:'/claims'}));
const mockKube = kube as jest.Mock;
const ready = {metadata:{name:'acme-dev'},spec:{teamName:'acme',environment:'dev'},status:{conditions:[{type:'Ready',status:'True'}]}};
const cm = {metadata:{name:'catalog-info',namespace:'tenant-acme-dev'},data:{'catalog-info.yaml':'apiVersion: backstage.io/v1alpha1\nkind: Component\nmetadata:\n  name: tenant-acme-dev\nspec:\n  type: tenant\n  lifecycle: production\n  owner: platform-team\n'}};
it('publishes only Ready claims, updates and removes them; API failure preserves previous snapshot', async () => {
  const provider=new PlatformProvider(); const applyMutation=jest.fn();
  await provider.connect({applyMutation} as any);
  mockKube.mockImplementation(async (url:string)=>url.endsWith('/tenants')?{items:[ready]}:url.endsWith('/postgresqlinstances')?{items:[]}:{items:[cm]});
  await provider.refresh(); expect(applyMutation.mock.calls[0][0].entities).toHaveLength(1);
  ready.status.conditions[0].status='False'; await provider.refresh();expect(applyMutation.mock.calls[1][0].entities).toHaveLength(0);
  mockKube.mockRejectedValue(new Error('API unavailable'));await expect(provider.refresh()).rejects.toThrow('API unavailable');expect(applyMutation).toHaveBeenCalledTimes(2);
});
