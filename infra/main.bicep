// Azure Container Apps deployment for Xero MCP Server
// On-demand / scale-to-zero: 0 min replicas, scales up on HTTP traffic.
//
// Prerequisites:
//   az login
//   az group create --name <rg> --location australiaeast
//   az deployment group create --resource-group <rg> --template-file infra/main.bicep \
//     --parameters xeroClientId=<id> xeroClientSecret=<secret> mcpAuthToken=<random-token>

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Short name prefix for all resources (lowercase, 3-8 chars)')
param prefix string = 'xeromcp'

@description('Container image to deploy, e.g. ghcr.io/org/xero-mcp-server:sha-abc123')
param containerImage string = 'ghcr.io/promptexecution/xero-mcp-server-b00t:latest'

@description('Xero OAuth2 client ID (stored in Key Vault)')
@secure()
param xeroClientId string

@description('Xero OAuth2 client secret (stored in Key Vault)')
@secure()
param xeroClientSecret string

@description('Bearer token required on /mcp once ingress is external — see MCP_AUTH_TOKEN in src/index.http.ts (#2/#5). Generate with e.g. `openssl rand -hex 32`.')
@secure()
param mcpAuthToken string

// ── Key Vault ────────────────────────────────────────────────────────────────

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${prefix}kv'
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    softDeleteRetentionInDays: 7
  }
}

resource kvSecretClientId 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'xero-client-id'
  properties: { value: xeroClientId }
}

resource kvSecretClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'xero-client-secret'
  properties: { value: xeroClientSecret }
}

resource kvSecretMcpAuthToken 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'mcp-auth-token'
  properties: { value: mcpAuthToken }
}

// ── Log Analytics ─────────────────────────────────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ── Container Apps Environment ────────────────────────────────────────────────

resource caEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}env'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ── Managed Identity for Key Vault access ─────────────────────────────────────

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}id'
  location: location
}

resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, identity.id, 'Key Vault Secrets User')
  scope: kv
  properties: {
    // Key Vault Secrets User
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Container App ─────────────────────────────────────────────────────────────

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}app'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identity.id}': {}
    }
  }
  properties: {
    environmentId: caEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 3000
        transport: 'http'
        // Sticky sessions ensure MCP SSE streams stay on the same replica.
        // Only matters if min replicas > 1; harmless at scale-to-zero.
        stickySessions: { affinity: 'sticky' }
      }
      secrets: [
        {
          name: 'xero-client-id'
          keyVaultUrl: kvSecretClientId.properties.secretUri
          identity: identity.id
        }
        {
          name: 'xero-client-secret'
          keyVaultUrl: kvSecretClientSecret.properties.secretUri
          identity: identity.id
        }
        {
          name: 'mcp-auth-token'
          keyVaultUrl: kvSecretMcpAuthToken.properties.secretUri
          identity: identity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'xero-mcp'
          image: containerImage
          env: [
            { name: 'XERO_CLIENT_ID',     secretRef: 'xero-client-id' }
            { name: 'XERO_CLIENT_SECRET', secretRef: 'xero-client-secret' }
            { name: 'MCP_AUTH_TOKEN',     secretRef: 'mcp-auth-token' }
            { name: 'NODE_ENV',           value: 'production' }
          ]
          resources: { cpu: json('0.25'), memory: '0.5Gi' }
          probes: [
            {
              type: 'Liveness'
              httpGet: { path: '/health', port: 3000 }
              initialDelaySeconds: 5
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: { path: '/health', port: 3000 }
              initialDelaySeconds: 3
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        // Scale to zero when idle; cold start ~2-4s for Node on alpine.
        minReplicas: 0
        maxReplicas: 3
        rules: [
          {
            name: 'http-scale'
            http: { metadata: { concurrentRequests: '10' } }
          }
        ]
      }
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output mcpEndpoint string = 'https://${containerApp.properties.configuration.ingress.fqdn}/mcp'
output healthEndpoint string = 'https://${containerApp.properties.configuration.ingress.fqdn}/health'
