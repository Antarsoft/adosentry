// PullPicket metrics infrastructure, deployed to one resource group:
//   az deployment group create -g <resource-group> -f infra/main.bicep -p infra/main.bicepparam
// See infra/README.md for the full sequence (Entra setup, image build, app).

targetScope = 'resourceGroup'

@description('Azure region for every resource. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names, e.g. pullpicket.')
@minLength(3)
@maxLength(20)
param namePrefix string

@description('Cosmos DB account name. Must be globally unique; the default appends a hash of the resource group.')
@minLength(3)
@maxLength(44)
param cosmosAccountName string = toLower('${namePrefix}-cosmos-${uniqueString(resourceGroup().id)}')

@description('SQL database name for metrics events.')
param cosmosDatabaseName string = 'AIMetrics'

@description('Container name for metrics events (hierarchical partition key /tenantId, /featureName).')
param cosmosContainerName string = 'Events'

@description('Container registry name. Must be globally unique, letters and digits only; the default appends a hash of the resource group.')
@minLength(5)
@maxLength(50)
param registryName string = toLower('${replace(namePrefix, '-', '')}${uniqueString(resourceGroup().id)}')

@description('Image tag in the registry to run, such as a git commit. Leave empty on the first deploy: everything but the Container App is created, so you can push the image and register the Entra apps first.')
param imageTag string = ''

@description('How POST /events is authenticated (the app\'s AUTH_MODE).')
@allowed(['entra', 'key', 'entra,key'])
param authMode string = 'entra'

@description('Tenant that issues the API\'s tokens (ENTRA_TENANT_ID). Defaults to this deployment\'s tenant.')
param entraTenantId string = tenant().tenantId

@description('The API app registration\'s application ID URI (api://...), from setup-entra.sh.')
param apiAppIdUri string = ''

@description('The API app registration\'s client (application) ID, from setup-entra.sh.')
param apiClientId string = ''

@description('Optional comma-separated object ids or client ids allowed to write without the Events.Write role (ENTRA_ALLOWED_PRINCIPALS).')
param entraAllowedPrincipals string = ''

@description('Shared key for AUTH_MODE key or entra,key (METRICS_API_KEY), at least 32 characters. Leave empty for entra.')
@secure()
param metricsApiKey string = ''

@description('Client ID of the dashboard app registration (Container Apps sign-in), from setup-entra.sh. Required once imageTag is set.')
param dashboardClientId string = ''

@description('Client secret of the dashboard app registration, from setup-entra.sh. Required once imageTag is set.')
@secure()
param dashboardClientSecret string = ''

@description('Minimum replicas; 0 scales to zero when idle.')
@minValue(0)
@maxValue(10)
param minReplicas int = 0

@description('Maximum replicas.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 2

@description('Tags applied to every resource.')
param tags object = {
  application: 'pullpicket'
}

module cosmos 'modules/cosmos.bicep' = {
  name: 'cosmos'
  params: {
    location: location
    accountName: cosmosAccountName
    databaseName: cosmosDatabaseName
    containerName: cosmosContainerName
    tags: tags
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    name: registryName
    tags: tags
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    name: '${namePrefix}-metrics-id'
    registryName: registry.outputs.name
    cosmosAccountName: cosmos.outputs.accountName
    tags: tags
  }
}

module environment 'modules/environment.bicep' = {
  name: 'environment'
  params: {
    location: location
    name: '${namePrefix}-env'
    logAnalyticsName: '${namePrefix}-logs'
    tags: tags
  }
}

var appName = '${namePrefix}-metrics'

module app 'modules/containerapp.bicep' = if (!empty(imageTag)) {
  name: 'app'
  params: {
    location: location
    name: appName
    environmentId: environment.outputs.id
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    registryLoginServer: registry.outputs.loginServer
    image: '${registry.outputs.loginServer}/pullpicket-metrics:${imageTag}'
    cosmosEndpoint: cosmos.outputs.endpoint
    cosmosDatabaseName: cosmos.outputs.databaseName
    cosmosContainerName: cosmos.outputs.containerName
    authMode: authMode
    entraTenantId: entraTenantId
    entraAudiences: filter([apiAppIdUri, apiClientId], audience => !empty(audience))
    entraAllowedPrincipals: entraAllowedPrincipals
    metricsApiKey: metricsApiKey
    dashboardClientId: dashboardClientId
    dashboardClientSecret: dashboardClientSecret
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    tags: tags
  }
}

@description('Resource ID of the Cosmos DB account.')
output cosmosAccountId string = cosmos.outputs.accountId

@description('COSMOS_ENDPOINT for the metrics API.')
output cosmosEndpoint string = cosmos.outputs.endpoint

@description('COSMOS_DATABASE for the metrics API.')
output cosmosDatabaseName string = cosmos.outputs.databaseName

@description('COSMOS_CONTAINER for the metrics API.')
output cosmosContainerName string = cosmos.outputs.containerName

@description('Container registry name, for az acr build.')
output registryName string = registry.outputs.name

@description('Container registry login server; the image is <loginServer>/pullpicket-metrics:<tag>.')
output registryLoginServer string = registry.outputs.loginServer

@description('Container App name.')
output containerAppName string = appName

@description('Public URL of the metrics API and dashboard. Known from the first deploy, before the app exists, so it can go into the Entra redirect URI.')
output metricsUrl string = 'https://${appName}.${environment.outputs.defaultDomain}'
