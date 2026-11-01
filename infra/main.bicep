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
