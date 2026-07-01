targetScope = 'resourceGroup'

@description('Azure region for this environment.')
param location string = resourceGroup().location

@description('Short azd environment name.')
@minLength(1)
param environmentName string

@description('Primary compute host for the dashboard pipeline.')
@allowed([
  'functionapp'
  'automation'
])
param computeKind string = 'functionapp'

@description('Hosted web surface for published dashboard artifacts.')
@allowed([
  'containerapp'
  'none'
])
param webKind string = 'containerapp'

@description('Dashboard packaging shape.')
@allowed([
  'auto'
  'hosted'
  'selfcontained'
  'dual'
])
param dashboardPackageMode string = 'auto'

@description('Whether the Function App should include Advanced Hunting enrichment by default.')
param includeAdvancedHunting bool = true

@description('Whether the Function App should reuse existing exports instead of generating fresh exports.')
param useExistingExportsOnly bool = false

@description('Function App export target.')
@allowed([
  'BlobStorage'
  'SharePoint'
  'StaticWebApp'
])
param exportTarget string = 'BlobStorage'

@description('Whether the Function App should mirror pipeline output into local trace files.')
param pipelineFileTraceEnabled bool = false

@description('Functions runtime for the Flex Consumption Function App.')
@allowed([
  'powershell'
])
param functionRuntime string = 'powershell'

@description('Functions runtime version for the Flex Consumption Function App.')
@allowed([
  '7.4'
])
param functionRuntimeVersion string = '7.4'

@description('Maximum scale-out instance count for the Function App.')
@minValue(40)
@maxValue(1000)
param maximumInstanceCount int = 100

@description('Function App instance memory in MB.')
@allowed([
  2048
  4096
])
param instanceMemoryMb int = 2048

@description('Placeholder image used by the scaffolded Container App until hosted-surface publish wiring lands.')
param placeholderContainerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

var token = toLower(uniqueString(subscription().id, resourceGroup().id, environmentName))
var storageAccountName = 'st${take(token, 22)}'
var workspaceName = 'log-${take(token, 20)}'
var appInsightsName = 'appi-${take(token, 19)}'
var functionAppName = 'func-${take(token, 18)}'
var functionPlanName = 'plan-${take(token, 18)}'
var functionIdentityName = 'uai-${take(token, 19)}'
var automationAccountName = 'aa-${take(token, 20)}'
var containerEnvironmentName = 'cae-${take(token, 18)}'
var containerAppName = 'aca-${take(token, 18)}'
var resolvedDashboardPackageMode = dashboardPackageMode == 'auto'
  ? (webKind == 'containerapp' ? 'hosted' : 'selfcontained')
  : dashboardPackageMode
var functionRuntimeDashboardDeliveryMode = resolvedDashboardPackageMode == 'hosted'
  ? 'Hosted'
  : (resolvedDashboardPackageMode == 'dual' ? 'Dual' : 'SelfContained')

module storage 'modules/core-storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    name: storageAccountName
    enableFunctionPackageContainer: computeKind == 'functionapp'
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: workspaceName
    applicationInsightsName: appInsightsName
  }
}

module functionApp 'modules/compute-functionapp.bicep' = if (computeKind == 'functionapp') {
  name: 'functionApp'
  params: {
    appName: functionAppName
    planName: functionPlanName
    identityName: functionIdentityName
    location: location
    functionRuntime: functionRuntime
    functionRuntimeVersion: functionRuntimeVersion
    maximumInstanceCount: maximumInstanceCount
    instanceMemoryMb: instanceMemoryMb
    storageAccountName: storage.outputs.name
    storageBlobEndpoint: storage.outputs.blobEndpoint
    deploymentContainerName: storage.outputs.functionPackageContainerName
    dashboardDeliveryMode: functionRuntimeDashboardDeliveryMode
    includeAdvancedHunting: includeAdvancedHunting
    useExistingExportsOnly: useExistingExportsOnly
    exportTarget: exportTarget
    pipelineFileTraceEnabled: pipelineFileTraceEnabled
    applicationInsightsId: monitoring.outputs.applicationInsightsId
    applicationInsightsConnectionString: monitoring.outputs.applicationInsightsConnectionString
    applicationInsightsInstrumentationKey: monitoring.outputs.applicationInsightsInstrumentationKey
  }
}

module functionStorageRoles 'modules/role-assignments.bicep' = if (computeKind == 'functionapp') {
  name: 'functionStorageRoles'
  params: {
    storageAccountName: storage.outputs.name
    principalId: functionApp!.outputs.identityPrincipalId
    assignBlobOwner: true
    assignBlobContributor: true
    assignQueueContributor: true
    assignTableContributor: true
  }
}

module automation 'modules/compute-automation.bicep' = if (computeKind == 'automation') {
  name: 'automation'
  params: {
    accountName: automationAccountName
    location: location
  }
}

module automationStorageRoles 'modules/role-assignments.bicep' = if (computeKind == 'automation') {
  name: 'automationStorageRoles'
  params: {
    storageAccountName: storage.outputs.name
    principalId: automation!.outputs.identityPrincipalId
    assignBlobOwner: true
    assignBlobContributor: true
    assignQueueContributor: false
    assignTableContributor: false
  }
}

module containerApp 'modules/web-containerapp.bicep' = if (webKind == 'containerapp') {
  name: 'containerApp'
  params: {
    containerAppName: containerAppName
    environmentName: containerEnvironmentName
    location: location
    image: placeholderContainerImage
    logAnalyticsWorkspaceName: workspaceName
  }
}

output computeKindResolved string = computeKind
output webKindResolved string = webKind
output dashboardPackageModeResolved string = resolvedDashboardPackageMode
output storageAccountName string = storage.outputs.name
output storageBlobEndpoint string = storage.outputs.blobEndpoint
output dashboardsContainerName string = storage.outputs.dashboardsContainerName
output templatesContainerName string = storage.outputs.templatesContainerName
output exportsContainerName string = storage.outputs.exportsContainerName
output functionPackageContainerName string = storage.outputs.functionPackageContainerName
output functionAppName string = computeKind == 'functionapp' ? functionApp!.outputs.name : ''
output functionAppId string = computeKind == 'functionapp' ? functionApp!.outputs.id : ''
output functionAppHostname string = computeKind == 'functionapp' ? functionApp!.outputs.hostname : ''
output automationAccountName string = computeKind == 'automation' ? automation!.outputs.name : ''
output automationAccountId string = computeKind == 'automation' ? automation!.outputs.id : ''
output defaultRunbookName string = computeKind == 'automation' ? automation!.outputs.defaultRunbookName : ''
output containerAppName string = webKind == 'containerapp' ? containerApp!.outputs.name : ''
output containerAppUrl string = webKind == 'containerapp' ? containerApp!.outputs.url : ''
output applicationInsightsName string = monitoring.outputs.applicationInsightsName
output applicationInsightsConnectionString string = monitoring.outputs.applicationInsightsConnectionString
