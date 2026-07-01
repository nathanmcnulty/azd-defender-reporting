#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ContainerAppName,
    [string]$ResourceGroupName,
    [string]$StorageAccountName,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [switch]$PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TextFromProcessOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Output = @()
    )

    if ($null -eq $Output -or $Output.Count -eq 0) {
        return ''
    }

    return (($Output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        }
        else {
            [string]$_
        }
    }) -join [Environment]::NewLine).Trim()
}

function Get-AzCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $commandOutput = @(az @Arguments 2>&1)
    $commandText = Get-TextFromProcessOutput -Output $commandOutput
    if ($LASTEXITCODE -ne 0) {
        throw $commandText
    }

    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return $null
    }

    return $commandText | ConvertFrom-Json
}

function Resolve-StorageAccountName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [string]$RequestedStorageAccountName
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedStorageAccountName)) {
        return $RequestedStorageAccountName
    }

    $storageAccounts = @(Get-AzCliJson -Arguments @(
        'resource', 'list',
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.Storage/storageAccounts',
        '--query', '[].name',
        '--output', 'json'
    ))

    if ($storageAccounts.Count -eq 0) {
        throw "No storage account resources were found in resource group '$ResourceGroupName'."
    }

    if ($storageAccounts.Count -gt 1) {
        throw "Multiple storage accounts were found in resource group '$ResourceGroupName'. Pass -StorageAccountName explicitly."
    }

    return [string]$storageAccounts[0]
}

$mode = & (Join-Path $PSScriptRoot 'Get-DeploymentMode.ps1')
if (-not $mode.RequiresHostedSurface) {
    throw 'WEB_KIND must be containerapp to publish or validate the hosted surface.'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ContainerAppName)) {
    throw 'ResourceGroupName and ContainerAppName are required.'
}

if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for hosted surface publish.'
}

$resolvedStorageAccountName = Resolve-StorageAccountName -ResourceGroupName $ResourceGroupName -RequestedStorageAccountName $StorageAccountName
$templatePublishResult = @(& (Join-Path $PSScriptRoot 'Publish-TemplateAssets.ps1') `
    -StorageAccountName $resolvedStorageAccountName `
    -RepositoryPath $RepositoryPath `
    -RepositoryUrl $RepositoryUrl `
    -Ref $Ref) | Where-Object {
        $_ -is [psobject] -and $_.PSObject.Properties.Match('ContainerName').Count -gt 0
    } | Select-Object -Last 1

if ($null -eq $templatePublishResult) {
    throw 'Publish-TemplateAssets.ps1 did not return the expected template publish result.'
}

$containerApp = Get-AzCliJson -Arguments @(
    'resource', 'show',
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.App/containerApps',
    '--name', $ContainerAppName,
    '--query', '{fqdn:properties.configuration.ingress.fqdn,provisioningState:properties.provisioningState}',
    '--output', 'json'
)

if ($null -eq $containerApp -or [string]::IsNullOrWhiteSpace([string]$containerApp.fqdn)) {
    throw "Container App '$ContainerAppName' was not found in resource group '$ResourceGroupName' or does not expose an ingress FQDN."
}

$containerAppUrl = 'https://{0}' -f ([string]$containerApp.fqdn)
$result = [PSCustomObject]@{
    ContainerAppName = $ContainerAppName
    ResourceGroupName = $ResourceGroupName
    ContainerAppUrl = $containerAppUrl
    ProvisioningState = [string]$containerApp.provisioningState
    StorageAccountName = $resolvedStorageAccountName
    TemplatesContainerName = $templatePublishResult.ContainerName
    EffectivePackageMode = $mode.EffectivePackageMode
}

if ($PlanOnly) {
    $result
    return
}

$statusCode = $null
try {
    $response = Invoke-WebRequest -Uri $containerAppUrl -UseBasicParsing -TimeoutSec 30
    $statusCode = [int]$response.StatusCode
}
catch {
    if ($null -ne $_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    else {
        throw
    }
}

$result | Add-Member -NotePropertyName HttpStatusCode -NotePropertyValue $statusCode
$result
