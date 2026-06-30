param location string
param name string
param enableFunctionPackageContainer bool = false

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
  }

  resource blobService 'blobServices' = {
    name: 'default'
    properties: {
      deleteRetentionPolicy: {
        enabled: true
        days: 7
      }
    }

    resource exportsContainer 'containers' = {
      name: 'exports'
      properties: {
        publicAccess: 'None'
      }
    }

    resource templatesContainer 'containers' = {
      name: 'templates'
      properties: {
        publicAccess: 'None'
      }
    }

    resource dashboardsContainer 'containers' = {
      name: 'dashboards'
      properties: {
        publicAccess: 'None'
      }
    }

    resource functionPackageContainer 'containers' = if (enableFunctionPackageContainer) {
      name: 'app-package'
      properties: {
        publicAccess: 'None'
      }
    }
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output exportsContainerName string = 'exports'
output templatesContainerName string = 'templates'
output dashboardsContainerName string = 'dashboards'
output functionPackageContainerName string = enableFunctionPackageContainer ? 'app-package' : ''

