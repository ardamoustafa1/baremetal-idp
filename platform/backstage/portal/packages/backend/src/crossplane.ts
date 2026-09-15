import { createBackendPlugin, coreServices } from '@backstage/backend-plugin-api';
import { Router } from 'express';
import { kube, claimBase } from './kube';

// DÜZELTME (Faz 12g, code review #9): "allow-all-policy" Backstage'in genel
// permission framework'ünü devre dışı bırakıyor — ama bu route zaten Backstage
// permission framework'üne HİÇ bağlı değildi (özel bir Express router'ı,
// `permissions.authorize()` çağırmıyor). Backend, Kubernetes'e KENDİ geniş
// yetkili ServiceAccount'ıyla gittiği için Kubernetes RBAC'ın kendisi de bunu
// engellemiyordu. Sonuç: herhangi bir authenticated Backstage kullanıcısı,
// ismini bilerek/tahmin ederek HERHANGİ BİR tenant'ın (kendisininki olmasa
// bile) claim/composite status'unu okuyabiliyordu — cross-tenant bilgi
// sızıntısı. Aşağıda, çağıranın Backstage grup üyeliği (`ownershipEntityRefs`)
// tenant'ın SAHİBİ olan Group'a göre KONTROL EDİLİYOR.
//
// DÜZELTME (Faz 12k, code review #12): grup adı ÖNCEDEN `group:default/
// ${claim.spec.oidcGroup}` (ör. "group:default/tenant-acme") VE
// `group:default/platform-admins` idi — AMA `oidcGroup` KUBERNETES OIDC
// grup adıdır (K8s RBAC/Vault için), Backstage'in KENDİ katalog Group
// entity'leriyle HİÇBİR OTOMATİK eşleme YOKTU (gerçek bir Keycloak→
// Backstage org data provider'ı bu repoda HİÇ YAZILMADI — bkz. catalog/
// organization.yaml'ın "OIDC grup senkronizasyonu" notu). AYRICA katalogda
// "platform-admins" DEĞİL "platform-team" adlı bir grup VARDI. Sonuç:
// mevcut, kataloğa TANIMLI operatör BİLE bu kontrolden 403 alırdı. Artık
// `compositions/tenant/function.k`'nin ZATEN ürettiği catalog-info.yaml'ın
// `spec.owner: team-${teamName}` alanıyla BİREBİR AYNI değer kullanılıyor
// (`team-<teamName>`, `oidcGroup` DEĞİL) — Backstage'in KENDİ, halihazırda
// var olan katalog ownership deseni; yeni bir kural İCAT EDİLMEDİ. Admin
// bypass'ı da katalogda GERÇEKTEN var olan "platform-team" grubuna çekildi
// (bkz. `platformCatalog.ts`'in AYNI grubu varsayılan owner olarak
// kullanması — tutarlı).
//
// AÇIK KALAN BOŞLUK (dürüstçe işaretli, bu görevde ÇÖZÜLMEDİ): bu statik
// catalog verisi (organization.yaml) ELLE bakımı yapılır — gerçek bir OIDC/
// Keycloak grup senkronizasyon provider'ı KURULANA KADAR, yeni bir tenant
// oluşturulduğunda `team-<teamName>` Group entity'si de ELLE eklenmelidir
// (bkz. organization.yaml'daki AYNI not).
const PLATFORM_ADMIN_GROUP = 'group:default/platform-team';

async function resolveOwnerGroup(kind: string, claim: any): Promise<string | undefined> {
  if (kind === 'Tenant') {
    const teamName = claim.spec?.teamName;
    return teamName ? `team-${teamName}` : undefined;
  }
  // PostgreSQLInstance'ın kendi teamName'i yok — sahipliği `tenantRef`
  // (tenant'ın namespace'i, örn. "tenant-acme-dev") üzerinden DOLAYLI.
  // O namespace'i üreten Tenant claim'ini bulup ONUN teamName'ini kullan.
  const tenantRef: string | undefined = claim.spec?.tenantRef;
  if (!tenantRef) return undefined;
  const list = await kube(`${claimBase}/tenants`);
  const owner = (list.items ?? []).find(
    (t: any) => `tenant-${t.spec?.teamName}-${t.spec?.environment}` === tenantRef,
  );
  return owner?.spec?.teamName ? `team-${owner.spec.teamName}` : undefined;
}

export default createBackendPlugin({
  pluginId: 'platform-crossplane',
  register(reg) {
    reg.registerInit({
      deps: {
        http: coreServices.httpRouter,
        httpAuth: coreServices.httpAuth,
        userInfo: coreServices.userInfo,
      },
      async init({ http, httpAuth, userInfo }) {
        const router = Router();
        router.get('/:kind/:name', async (req, res, next) => {
          try {
            const plural = ({Tenant:'tenants', PostgreSQLInstance:'postgresqlinstances'} as Record<string,string>)[req.params.kind];
            if (!plural || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(req.params.name)) { res.status(400).end(); return; }
            const claim = await kube(`${claimBase}/${plural}/${req.params.name}`);

            const credentials = await httpAuth.credentials(req, { allow: ['user'] });
            const { ownershipEntityRefs = [] } = await userInfo.getUserInfo(credentials);
            const ownerGroup = await resolveOwnerGroup(req.params.kind, claim);
            const ownerGroupRef = ownerGroup ? `group:default/${ownerGroup}` : undefined;
            const isOwner = !!ownerGroupRef && ownershipEntityRefs.includes(ownerGroupRef);
            const isPlatformAdmin = ownershipEntityRefs.includes(PLATFORM_ADMIN_GROUP);
            if (!isOwner && !isPlatformAdmin) {
              res.status(403).json({ error: 'Bu tenant kaynağına erişim yetkiniz yok.' });
              return;
            }

            const ref = claim.spec.resourceRef;
            const xrPlural = plural === 'tenants' ? 'xtenants' : 'xpostgresqlinstances';
            const composite = ref ? await kube(`/apis/platform.internal/v1alpha1/${xrPlural}/${encodeURIComponent(ref.name)}`) : null;
            res.json({claim:{name:claim.metadata.name, conditions:claim.status?.conditions ?? []}, composite:composite ? {name:composite.metadata.name, conditions:composite.status?.conditions ?? []} : null});
          } catch (error) { next(error); }
        });
        // Default Backstage backend authentication remains required; ownership
        // is additionally enforced per-request above.
        http.use(router);
      },
    });
  },
});
