// Run the actual Backstage actions. Only the outbound GitHub client is replaced.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {createFetchTemplateAction} = require('@backstage/plugin-scaffolder-backend');
const {createPublishGithubPullRequestAction} = require('@backstage/plugin-scaffolder-backend-module-github');
const {ConfigReader} = require('@backstage/config');
const {ScmIntegrations} = require('@backstage/integration');
const yaml = require('yaml');
const {spawnSync} = require('node:child_process');
const integrations = ScmIntegrations.fromConfig(new ConfigReader({integrations:{github:[{host:'github.com',token:'test-only'}]}}));
(async () => {
 for (const [template,values,relative] of [
  ['create-tenant',{cluster:'platform',teamName:'testteam',environment:'dev',costCenter:'CC-1042',oidcGroup:'tenant-testteam',quotaTier:'small',networkTier:'isolated'},'clusters/platform/tenants/testteam-dev.yaml'],
  ['request-postgres',{cluster:'platform',name:'test-db',tenantRef:'tenant-testteam-dev',size:'medium',version:'16',highAvailability:true},'clusters/platform/postgresql/test-db.yaml'],
 ]) {
  const workspacePath = await fs.mkdtemp(path.join(os.tmpdir(),'backstage-actions-'));
  const tempDirs=[];
  try {
   const outputs={};
   const ctx={workspacePath,logger:{info(){},warn(){},error(){},debug(){}},output:(key,value)=>outputs[key]=value,checkpoint:async ({fn})=>fn(),createTemporaryDirectory:async ()=>{const dir=await fs.mkdtemp(path.join(os.tmpdir(),'backstage-fetch-'));tempDirs.push(dir);return dir;},templateInfo:{baseUrl:`file://${path.resolve('../templates',template,'template.yaml')}`}};
   await createFetchTemplateAction({reader:{},integrations}).handler({...ctx,input:{url:'./skeleton',values}});
   const content=await fs.readFile(path.join(workspacePath,relative),'utf8');
   const claim=yaml.parse(content);assert.equal(claim.metadata.namespace,'tenant-requests');
   let payload;
   await createPublishGithubPullRequestAction({integrations,clientFactory:async()=>({createPullRequest:async options=>{payload=options;return {data:{html_url:'https://github.com/test/tenant-requests/pull/42',number:42,base:{ref:'main'}}};}})}).handler({...ctx,input:{repoUrl:'github.com?owner=test&repo=tenant-requests',branchName:'test-request',title:'test',description:'test',targetBranchName:'main'}});
   assert.equal(payload.base,'main');assert.equal(outputs.pullRequestNumber,42);
   const sent=payload.changes[0].files[relative];assert.equal(Buffer.from(sent.content,sent.encoding).toString(),content);
   const destination=path.resolve('../../../tenant-requests',relative);
   await fs.mkdir(path.dirname(destination),{recursive:true});
   await fs.writeFile(destination,content,{flag:'wx'});
   try {
    const result=spawnSync('bash',['.github/scripts/validate-claims.sh'],{cwd:path.resolve('../../../tenant-requests'),env:{...process.env,PLATFORM_REPO_DIR:path.resolve('../../..'),CHANGED_FILES:relative},encoding:'utf8'});
    assert.equal(result.status,0,result.stdout+result.stderr);
   } finally {await fs.unlink(destination);}
   console.log(`PASS actual fetch:template → publish:github:pull-request → schema/render/policy: ${relative}`);
  } finally {await fs.rm(workspacePath,{recursive:true,force:true});for(const dir of tempDirs)await fs.rm(dir,{recursive:true,force:true});}
 }
})().catch(error=>{console.error(error);process.exit(1);});
