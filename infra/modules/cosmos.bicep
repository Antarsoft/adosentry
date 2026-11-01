// Serverless Cosmos DB (NoSQL API) for the metrics service.
// Key-based auth is disabled: the app reaches Cosmos with an Entra identity
// and a data-plane role assignment (see I3 in the plan), never with an account key.

@description('Azure region for the account.')
param location string

@description('Cosmos DB account name: 3-44 characters, lowercase letters, digits and hyphens.')
@minLength(3)
@maxLength(44)
param accountName string

@description('SQL database name. The metrics API reads it from COSMOS_DATABASE.')
param databaseName string

@description('Container name. The metrics API reads it from COSMOS_CONTAINER.')
param containerName string

@description('Tags applied to every resource.')
param tags object

resource account 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: accountName
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [
      { name: 'EnableServerless' }
    ]
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    disableLocalAuth: true
    disableKeyBasedMetadataWriteAccess: true
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: 'Enabled'
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: account
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource container 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: database
  name: containerName
  properties: {
    resource: {
      id: containerName
      partitionKey: {
        paths: ['/featureName']
        kind: 'Hash'
        version: 2
      }
    }
  }
}

@description('Resource ID of the Cosmos DB account, for role assignments.')
output accountId string = account.id

@description('Cosmos DB account name.')
output accountName string = account.name

@description('Document endpoint; set it as COSMOS_ENDPOINT on the metrics API.')
output endpoint string = account.properties.documentEndpoint

@description('SQL database name.')
output databaseName string = database.name

@description('Container name.')
output containerName string = container.name
