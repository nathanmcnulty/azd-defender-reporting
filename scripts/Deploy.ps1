#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ResourceGroupName = $env:AZURE_RESOURCE_GROUP,
    [switch]$PlanOnly,
    [switch]$SkipProvision,
    [switch]$SkipPublish,
    [switch]$SkipValidation,
    [switch]$RunSmokeTest,
    [string]$AccessToken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

if (-not (Get-Command -Name 'azd' -ErrorAction SilentlyContinue)) {
    throw 'Azure Developer CLI (azd) is required.'
}

if (-not $SkipValidation) {
    & (Join-Path $PSScriptRoot 'Validate-Repository.ps1') -ValidateAllUpstreamContracts
}

if ($PlanOnly) {
    & azd provision --preview
    if ($LASTEXITCODE -ne 0) {
        throw 'azd provision --preview failed.'
    }
    return
}

if (-not $SkipProvision) {
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
    & (Join-Path $PSScriptRoot 'Publish-Deployment.ps1') -ResourceGroupName $resolvedResourceGroupName
}

if ($RunSmokeTest) {
    if ([string]::IsNullOrWhiteSpace($resolvedResourceGroupName)) {
        throw 'ResourceGroupName is required for live smoke testing.'
    }
    & (Join-Path $PSScriptRoot 'Test-LiveDeployment.ps1') -ResourceGroupName $resolvedResourceGroupName -AccessToken $AccessToken
}
