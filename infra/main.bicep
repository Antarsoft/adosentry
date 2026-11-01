// AdoSentry metrics infrastructure, deployed to one resource group:
//   az deployment group create -g <resource-group> -f infra/main.bicep -p infra/main.bicepparam
// Today this creates the Cosmos DB store; the registry, Container App and
// identity wiring (I2, I3, I5 in the plan) are added as further modules.

targetScope = 'resourceGroup'

@description('Azure region for every resource. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('Short prefix used to build resource names, e.g. adosentry.')
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

@description('Tags applied to every resource.')
param tags object = {
  application: 'adosentry'
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

@description('Resource ID of the Cosmos DB account.')
output cosmosAccountId string = cosmos.outputs.accountId

@description('COSMOS_ENDPOINT for the metrics API.')
output cosmosEndpoint string = cosmos.outputs.endpoint

@description('COSMOS_DATABASE for the metrics API.')
output cosmosDatabaseName string = cosmos.outputs.databaseName

@description('COSMOS_CONTAINER for the metrics API.')
output cosmosContainerName string = cosmos.outputs.containerName
