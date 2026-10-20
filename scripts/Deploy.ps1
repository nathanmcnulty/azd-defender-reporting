#Requires -Version 7.6

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroupName = $env:AZURE_RESOURCE_GROUP,
    [switch]$PlanOnly,
    [switch]$SkipProvision,
    [switch]$SkipPublish,
    [switch]$SkipValidation,
    [switch]$ManualOnly,
    [switch]$RunSmokeTest,
    [string]$AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

if ($ManualOnly) {
    $mode = & (Join-Path $PSScriptRoot 'Get-DeploymentMode.ps1')
    Assert-ManualAutomationMode -Mode $mode
}

Initialize-PublishTarget -SubscriptionId $SubscriptionId -TenantId $TenantId
$SubscriptionId = $script:PublishTarget.SubscriptionId
$TenantId = $script:PublishTarget.TenantId


if ((-not $SkipProvision -or $PlanOnly) -and -not (Get-Command -Name 'azd' -ErrorAction SilentlyContinue)) {
    throw 'Azure Developer CLI (azd) is required.'
}

if (-not $SkipValidation) {
    & (Join-Path $PSScriptRoot 'Validate-Repository.ps1') -ValidateAllUpstreamContracts
}

if (-not $SkipProvision -or $PlanOnly) {
    $selected = Get-AzdEnvironmentValues
    if (-not $selected.ContainsKey('AZURE_SUBSCRIPTION_ID') -or -not $selected.ContainsKey('AZURE_TENANT_ID') -or
        $selected['AZURE_SUBSCRIPTION_ID'] -ine $SubscriptionId -or $selected['AZURE_TENANT_ID'] -ine $TenantId) {
        throw 'The selected azd environment must match the explicit subscription and tenant before provisioning.'
    }
}

if ($PlanOnly) {
    Assert-PublishTarget
    & azd provision --preview
    if ($LASTEXITCODE -ne 0) {
        throw 'azd provision --preview failed.'
    }
    return
}

if (-not $SkipProvision) {
    Assert-PublishTarget
    & azd provision
    if ($LASTEXITCODE -ne 0) {
        throw 'azd provision failed.'
    }
}

$resolvedResourceGroupName = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Get-EnvironmentValue -Name 'AZURE_RESOURCE_GROUP'
}
else {
    $ResourceGroupName
}

if (-not $SkipPublish) {
    if ([string]::IsNullOrWhiteSpace($resolvedResourceGroupName)) {
        throw 'ResourceGroupName could not be resolved after provisioning.'
    }
    & (Join-Path $PSScriptRoot 'Publish-Deployment.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $resolvedResourceGroupName -ManualOnly:$ManualOnly
}

if ($RunSmokeTest) {
    if ([string]::IsNullOrWhiteSpace($resolvedResourceGroupName)) {
        throw 'ResourceGroupName is required for live smoke testing.'
    }
    & (Join-Path $PSScriptRoot 'Test-LiveDeployment.ps1') -SubscriptionId $SubscriptionId -TenantId $TenantId -ResourceGroupName $resolvedResourceGroupName -AccessToken $AccessToken
}
