param location string
param accountName string

resource automationAccount 'Microsoft.Automation/automationAccounts@2021-06-22' = {
  name: accountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    encryption: {
      keySource: 'Microsoft.Automation'
    }
    publicNetworkAccess: true
    sku: {
      name: 'Basic'
    }
  }
}

output id string = automationAccount.id
output name string = automationAccount.name
output identityPrincipalId string = automationAccount.identity.principalId
output defaultRunbookName string = 'DashboardPipeline'
