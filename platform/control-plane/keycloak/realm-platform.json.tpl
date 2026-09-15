{
  "realm": "${KEYCLOAK_REALM}",
  "displayName": "Platform",
  "enabled": true,

  "sslRequired": "external",

  "registrationAllowed": false,
  "resetPasswordAllowed": true,
  "rememberMe": true,
  "verifyEmail": false,
  "loginWithEmailAllowed": true,
  "duplicateEmailsAllowed": false,

  "accessTokenLifespan": 900,
  "ssoSessionIdleTimeout": 3600,
  "ssoSessionMaxLifespan": 36000,
  "offlineSessionIdleTimeout": 2592000,

  "bruteForceProtected": true,
  "permanentLockout": false,
  "maxFailureWaitSeconds": 900,
  "failureFactor": 10,

  "passwordPolicy": "length(14) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername and passwordHistory(3)",

  "groups": [
    {
      "name": "platform-admins",
      "path": "/platform-admins",
      "attributes": {
        "description": ["Platform ekibi — cluster-admin eşleniği"]
      }
    },
    {
      "name": "platform-viewers",
      "path": "/platform-viewers",
      "attributes": {
        "description": ["Salt okunur platform erişimi"]
      }
    },
    {
      "name": "platform-tenant-requesters",
      "path": "/platform-tenant-requesters",
      "attributes": {
        "description": [
          "Faz 6b (Tenant guardrails) ekleme: yeni bir Tenant claim'i",
          "açabilecek ekipler. policies/rbac/tenant-claim-rbac.yaml ve",
          "policies/validation/04-restrict-tenant-claim-creation.yaml",
          "bu gruba bağlıdır."
        ]
      }
    }
  ],

  "roles": {
    "realm": [
      {
        "name": "platform-admin",
        "description": "Platform yöneticisi. Tüm katmanlara tam erişim.",
        "composite": false
      },
      {
        "name": "platform-viewer",
        "description": "Salt okunur platform erişimi.",
        "composite": false
      },
      {
        "name": "tenant-admin",
        "description": "Kendi tenant namespace'inde yönetici. Faz 6'da kullanılacak.",
        "composite": false
      },
      {
        "name": "tenant-developer",
        "description": "Kendi tenant namespace'inde geliştirici. Faz 6'da kullanılacak.",
        "composite": false
      }
    ]
  },

  "clientScopes": [
    {
      "name": "groups",
      "description": "Kullanicinin grup uyelikleri. K8s API server ve ArgoCD grup bazli yetkilendirme icin kullanir.",
      "protocol": "openid-connect",
      "attributes": {
        "include.in.token.scope": "true",
        "display.on.consent.screen": "false"
      },
      "protocolMappers": [
        {
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
            "claim.name": "groups"
          }
        }
      ]
    }
  ],

  "defaultDefaultClientScopes": [
    "role_list", "profile", "email", "roles", "web-origins", "groups"
  ],

  "clients": [
    {
      "clientId": "kubernetes",
      "name": "Kubernetes API Server",
      "enabled": true,
      "publicClient": true,
      "protocol": "openid-connect",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true,
      "redirectUris": ["http://localhost:8000/*", "http://localhost:18000/*"],
      "defaultClientScopes": ["openid", "profile", "email", "groups"]
    },
    {
      "clientId": "backstage",
      "name": "Backstage Developer Portal",
      "enabled": true,
      "publicClient": false,
      "protocol": "openid-connect",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "redirectUris": [
        "https://backstage.${PLATFORM_BASE_DOMAIN}/api/auth/oidc/handler/frame"
      ],
      "webOrigins": ["https://backstage.${PLATFORM_BASE_DOMAIN}"],
      "defaultClientScopes": ["openid", "profile", "email", "roles", "groups"]
    }
  ],

  "users": []
}
