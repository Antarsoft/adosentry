targetScope = 'subscription'

param environment string
param location string = 'westeurope'
param deployerPrincipalId string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-orders-${environment}'
  location: location
}

module sql 'modules/sql.bicep' = {
  scope: rg
  name: 'sql'
  params: {
    serverName: 'sql-orders-core-${environment}'
    location: location
  }
}

resource deployerOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: newGuid()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8e3af657-a8ff-443c-a75c-2fe8c4bcb635')
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
  }
}
