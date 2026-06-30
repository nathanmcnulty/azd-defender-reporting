param location string
param appName string
param planName string
param identityName string
param storageAccountName string
param storageBlobEndpoint string
param deploymentContainerName string
param dashboardDeliveryMode string
param includeAdvancedHunting bool
param useExistingExportsOnly bool
param exportTarget string
param pipelineFileTraceEnabled bool
param functionRuntime string
param functionRuntimeVersion string
param maximumInstanceCount int
param instanceMemoryMb int
param applicationInsightsId string
param applicationInsightsConnectionString string
param applicationInsightsInstrumentationKey string

var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: appName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      minTlsVersion: '1.2'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageBlobEndpoint}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: userAssignedIdentity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMb
      }
      runtime: {
        name: functionRuntime
        version: functionRuntimeVersion
      }
    }
  }

  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      AzureWebJobsStorage__accountName: storageAccountName
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__clientId: userAssignedIdentity.properties.clientId
      FUNCTIONS_EXTENSION_VERSION: '~4'
      STORAGE_ACCOUNT_NAME: storageAccountName
      DASHBOARD_DELIVERY_MODE: dashboardDeliveryMode
      INCLUDE_ADVANCED_HUNTING: includeAdvancedHunting ? 'true' : 'false'
      USE_EXISTING_EXPORTS_ONLY: useExistingExportsOnly ? 'true' : 'false'
      EXPORT_TARGET: exportTarget
      PIPELINE_FILE_TRACE_ENABLED: pipelineFileTraceEnabled ? 'true' : 'false'
      APPINSIGHTS_INSTRUMENTATIONKEY: applicationInsightsInstrumentationKey
      APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${userAssignedIdentity.properties.clientId};Authorization=AAD'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  scope: resourceGroup()
  name: last(split(applicationInsightsId, '/'))
}

resource monitoringRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, applicationInsights.id, userAssignedIdentity.id, 'Monitoring Metrics Publisher')
  scope: applicationInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: userAssignedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output id string = functionApp.id
output name string = functionApp.name
output hostname string = functionApp.properties.defaultHostName
output identityPrincipalId string = userAssignedIdentity.properties.principalId
output identityClientId string = userAssignedIdentity.properties.clientId
