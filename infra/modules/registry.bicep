// Azure Container Registry for the metrics image (D9: ACR only for 1.0).
// No admin user and no anonymous pull: the Container App pulls with its
// managed identity, which holds AcrPull on this registry (see identity.bicep).

@description('Azure region for the registry.')
param location string

@description('Registry name: 5-50 letters and digits, globally unique.')
@minLength(5)
@maxLength(50)
param name string

@description('Tags applied to every resource.')
param tags object

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

@description('Resource ID of the registry, for role assignments.')
output id string = registry.id

@description('Registry name, for az acr build and az acr login.')
output name string = registry.name

@description('Login server, such as <name>.azurecr.io; image references start with it.')
output loginServer string = registry.properties.loginServer
