targetScope = 'subscription'

param environment string
param location string = 'westeurope'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-orders-${environment}'
  location: location
}

module sql 'modules/sql.bicep' = {
  scope: rg
  name: 'sql'
  params: {
    serverName: 'sql-orders-${environment}'
    location: location
  }
}
