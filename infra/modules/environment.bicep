// Container Apps environment (Consumption) with its logs in Log Analytics.
// It is deployed before the app so its default domain, and so the app's
// public URL, is known in time for the Entra redirect URI (setup-entra.sh).

@description('Azure region for the environment and workspace.')
param location string

@description('Container Apps environment name.')
param name string

@description('Log Analytics workspace name.')
param logAnalyticsName string

@description('Days to keep logs.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Tags applied to every resource.')
param tags object

resource logs 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
  }
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

@description('Resource ID of the environment.')
output id string = environment.id

@description('Default domain; an app named <app> is served at https://<app>.<defaultDomain>.')
output defaultDomain string = environment.properties.defaultDomain
