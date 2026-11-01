// The metrics API and dashboard as a Container App.
//
// It runs as the user-assigned identity from identity.bicep: that identity
// pulls the image from ACR and signs in to Cosmos DB (key auth is disabled),
// found by the app through AZURE_CLIENT_ID. POST /events is guarded by the
// app itself (AUTH_MODE); the dashboard and /metrics/* are guarded by
// Container Apps sign-in.

@description('Azure region for the app.')
param location string

@description('Container App name: lowercase letters, digits and hyphens, at most 32 characters.')
@minLength(2)
@maxLength(32)
param name string

@description('Resource ID of the Container Apps environment.')
param environmentId string

@description('Resource ID of the user-assigned identity the app runs as.')
param identityId string

@description('Client ID of that identity.')
param identityClientId string

@description('Registry login server, such as <name>.azurecr.io.')
param registryLoginServer string

@description('Full image reference, such as <name>.azurecr.io/pullpicket-metrics:<tag>.')
param image string

@description('Cosmos DB document endpoint.')
param cosmosEndpoint string

@description('Cosmos DB database name.')
param cosmosDatabaseName string

@description('Cosmos DB container name.')
param cosmosContainerName string

@description('AUTH_MODE for POST /events.')
@allowed(['entra', 'key', 'entra,key'])
param authMode string

@description('ENTRA_TENANT_ID: the tenant that issues tokens.')
param entraTenantId string

@description('ENTRA_AUDIENCE: accepted audiences, normally the API app\'s application ID URI and client id.')
param entraAudiences array

@description('ENTRA_ALLOWED_PRINCIPALS: optional comma-separated object ids or client ids allowed to write without the Events.Write role.')
param entraAllowedPrincipals string

@description('METRICS_API_KEY for AUTH_MODE key or entra,key; stored as a Container Apps secret.')
@secure()
param metricsApiKey string

@description('Minimum replicas. 0 scales to zero when idle (the first request after idle waits a few seconds).')
@minValue(0)
@maxValue(10)
param minReplicas int

@description('Maximum replicas.')
@minValue(1)
@maxValue(10)
param maxReplicas int

@description('Tags applied to every resource.')
param tags object

var usesKey = contains(authMode, 'key')

var keySecrets = usesKey
  ? [
      {
        name: 'metrics-api-key'
        value: metricsApiKey
      }
    ]
  : []

var baseEnv = [
  { name: 'COSMOS_ENDPOINT', value: cosmosEndpoint }
  { name: 'COSMOS_DATABASE', value: cosmosDatabaseName }
  { name: 'COSMOS_CONTAINER', value: cosmosContainerName }
  { name: 'AZURE_CLIENT_ID', value: identityClientId }
  { name: 'AUTH_MODE', value: authMode }
]

var entraEnv = contains(authMode, 'entra')
  ? concat(
      [
        { name: 'ENTRA_TENANT_ID', value: entraTenantId }
        { name: 'ENTRA_AUDIENCE', value: join(entraAudiences, ',') }
      ],
      empty(entraAllowedPrincipals) ? [] : [{ name: 'ENTRA_ALLOWED_PRINCIPALS', value: entraAllowedPrincipals }]
    )
  : []

var keyEnv = usesKey ? [{ name: 'METRICS_API_KEY', secretRef: 'metrics-api-key' }] : []

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: registryLoginServer
          identity: identityId
        }
      ]
      secrets: keySecrets
    }
    template: {
      containers: [
        {
          name: 'metrics'
          image: image
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: concat(baseEnv, entraEnv, keyEnv)
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              periodSeconds: 30
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/healthz'
                port: 8080
              }
              periodSeconds: 10
            }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

@description('Container App name.')
output name string = app.name

@description('Public URL of the app.')
output url string = 'https://${app.properties.configuration.ingress.fqdn}'
