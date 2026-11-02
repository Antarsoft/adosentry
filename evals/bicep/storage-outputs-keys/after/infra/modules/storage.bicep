@description('Storage account name.')
param name string
param location string = resourceGroup().location
param tags object = {}
param partnerSigningKey string

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Standard_GRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    allowSharedKeyAccess: false
  }
}

resource signingSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'kv-partners/partner-signing-key'
  properties: { value: partnerSigningKey }
}

output id string = storage.id
output primaryKey string = storage.listKeys().keys[0].value
