param storageAccountName string
param principalId string
param principalType string = 'ServicePrincipal'
param assignBlobOwner bool = false
param assignBlobContributor bool = true
param assignQueueContributor bool = false
param assignTableContributor bool = false

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource blobOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignBlobOwner) {
  name: guid(subscription().id, storageAccount.id, principalId, 'Storage Blob Data Owner')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: principalId
    principalType: principalType
  }
}

resource blobContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignBlobContributor) {
  name: guid(subscription().id, storageAccount.id, principalId, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: principalId
    principalType: principalType
  }
}

resource queueContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignQueueContributor) {
  name: guid(subscription().id, storageAccount.id, principalId, 'Storage Queue Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: principalId
    principalType: principalType
  }
}

resource tableContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignTableContributor) {
  name: guid(subscription().id, storageAccount.id, principalId, 'Storage Table Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: principalId
    principalType: principalType
  }
}

