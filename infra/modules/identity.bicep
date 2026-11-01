// The metrics app's identity and what it may do.
//
// A user-assigned identity rather than the app's system-assigned one: a
// system-assigned identity only exists once the app does, so its AcrPull
// grant would land after the app's first image pull and that pull would fail.
// Creating the identity and its grants first lets the app start on the first
// deploy. The app finds this identity through AZURE_CLIENT_ID.

@description('Azure region for the identity.')
param location string

@description('Managed identity name.')
param name string

@description('Name of the container registry the app pulls from (AcrPull).')
param registryName string

@description('Tags applied to every resource.')
param tags object

// Built-in role: AcrPull.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: name
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: registryName
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, acrPullRoleId)
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Resource ID of the identity, to attach it to the app.')
output id string = identity.id

@description('Client ID of the identity; the app gets it as AZURE_CLIENT_ID.')
output clientId string = identity.properties.clientId

@description('Object (principal) ID of the identity, for data-plane role assignments.')
output principalId string = identity.properties.principalId
