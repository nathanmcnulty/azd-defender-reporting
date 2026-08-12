#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$ApplyDefaults,
    [switch]$PersistAzdEnv,
    [switch]$CheckUpstreamPath,
    [string]$CommandName = 'manual'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$repoRoot = Split-Path -Path $scriptRoot -Parent

. (Join-Path $scriptRoot 'Common-AzurePublish.ps1')

function Set-ProcessAndAzdDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $current = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($current) -or -not $ApplyDefaults) {
        return
    }

    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')

    if (-not $ApplyDefaults -or -not $PersistAzdEnv) {
        return
    }

    $azd = Get-Command -Name 'azd' -ErrorAction SilentlyContinue
    if ($null -eq $azd) {
        return
    }

    try {
        & $azd.Source env set $Name $Value | Out-Null
    }
    catch {
        Write-Verbose "Unable to persist azd env default '$Name'. $_"
    }
}

function Set-DeployerPrincipalDefaults {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('DEPLOYER_PRINCIPAL_ID', 'Process'))) {
        return
    }

    $azPath = (Get-Command -Name 'az' -ErrorAction SilentlyContinue)?.Source
    if (-not $azPath) {
        return
    }

    try {
        $principalType = (& $azPath account show --query user.type --output tsv 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($principalType)) {
            $principalType = 'user'
        }

        if ($principalType -eq 'user') {
            $principalId = (& $azPath ad signed-in-user show --query id --output tsv 2>$null | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($principalId)) {
                return
            }

            Set-ProcessAndAzdDefault -Name 'DEPLOYER_PRINCIPAL_ID' -Value $principalId
            Set-ProcessAndAzdDefault -Name 'DEPLOYER_PRINCIPAL_TYPE' -Value 'User'
            return
        }

        $servicePrincipalAppId = (& $azPath account show --query user.name --output tsv 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($servicePrincipalAppId)) {
            return
        }

        $servicePrincipalObjectId = (& $azPath ad sp show --id $servicePrincipalAppId --query id --output tsv 2>$null | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($servicePrincipalObjectId)) {
            return
        }

        Set-ProcessAndAzdDefault -Name 'DEPLOYER_PRINCIPAL_ID' -Value $servicePrincipalObjectId
        Set-ProcessAndAzdDefault -Name 'DEPLOYER_PRINCIPAL_TYPE' -Value 'ServicePrincipal'
    }
    catch {
        Write-Verbose "Unable to determine deployer principal defaults. $_"
    }
}

function Import-AzdEnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return $processValue
    }

    $azdValues = Get-AzdEnvironmentValues
    if (-not $azdValues.ContainsKey($Name)) {
        return $null
    }

    $resolvedValue = [string]$azdValues[$Name]
    if ([string]::IsNullOrWhiteSpace($resolvedValue)) {
        return $null
    }

    [Environment]::SetEnvironmentVariable($Name, $resolvedValue, 'Process')
    return $resolvedValue
}

function Test-CanPrompt {
    [CmdletBinding()]
    param()

    if ($env:CI -or $env:GITHUB_ACTIONS) {
        return $false
    }

    try {
        $null = $Host.UI.RawUI
        return [Environment]::UserInteractive
    }
    catch {
        return $false
    }
}

function Resolve-HostedAuthSecurityGroupSetting {
    [CmdletBinding()]
    param(
        [string]$CurrentValue,
        [bool]$RequiresHostedSurface,
        [bool]$SkipHostedAuthSetup
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue) -or -not $RequiresHostedSurface -or $SkipHostedAuthSetup) {
        return $CurrentValue
    }

    if ($CommandName -notin @('preprovision', 'publish-deployment')) {
        return $CurrentValue
    }

    if (-not (Test-CanPrompt)) {
        return $CurrentValue
    }

    Write-Warning 'Hosted publish defaults to Entra Easy Auth. Enter a group object ID or unique display name to restrict access, or press Enter to allow any authenticated user in the tenant.'
    $promptValue = Read-Host 'Optional HOSTED_AUTH_SECURITY_GROUP'
    if ([string]::IsNullOrWhiteSpace($promptValue)) {
        return $null
    }

    $resolvedValue = $promptValue.Trim()
    Set-ProcessAndAzdDefault -Name 'HOSTED_AUTH_SECURITY_GROUP' -Value $resolvedValue
    return $resolvedValue
}

Set-ProcessAndAzdDefault -Name 'COMPUTE_KIND' -Value 'functionapp'
Set-ProcessAndAzdDefault -Name 'WEB_KIND' -Value 'containerapp'
Set-ProcessAndAzdDefault -Name 'DASHBOARD_PACKAGE_MODE' -Value 'auto'
Set-ProcessAndAzdDefault -Name 'SKIP_HOSTED_AUTH_SETUP' -Value 'false'
$compatibilityLock = Get-UpstreamCompatibilityLock
Set-ProcessAndAzdDefault -Name 'DEFENDER_REPORTING_REPO' -Value ([string]$compatibilityLock.repository)
Set-ProcessAndAzdDefault -Name 'DEFENDER_REPORTING_REF' -Value ([string]$compatibilityLock.ref)

@(
    'AZURE_RESOURCE_GROUP',
    'COMPUTE_KIND',
    'WEB_KIND',
    'DASHBOARD_PACKAGE_MODE',
    'SKIP_HOSTED_AUTH_SETUP',
    'HOSTED_AUTH_SECURITY_GROUP',
    'HOSTED_AUTH_APP_DISPLAY_NAME',
    'DEFENDER_REPORTING_REPO',
    'DEFENDER_REPORTING_REF',
    'DEFENDER_REPORTING_PATH',
    'DEPLOYER_PRINCIPAL_ID',
    'DEPLOYER_PRINCIPAL_TYPE'
) | ForEach-Object {
    Import-AzdEnvironmentValue -Name $_ | Out-Null
}

Set-DeployerPrincipalDefaults

$mode = & (Join-Path $scriptRoot 'Get-DeploymentMode.ps1')
$resolvedSkipHostedAuthSetup = Resolve-BooleanString -Value (Get-EnvironmentValue -Name 'SKIP_HOSTED_AUTH_SETUP') -Default $false
$hostedAuthSecurityGroup = Resolve-HostedAuthSecurityGroupSetting `
    -CurrentValue (Get-EnvironmentValue -Name 'HOSTED_AUTH_SECURITY_GROUP') `
    -RequiresHostedSurface ([bool]$mode.RequiresHostedSurface) `
    -SkipHostedAuthSetup $resolvedSkipHostedAuthSetup
$deployerPrincipalId = Get-EnvironmentValue -Name 'DEPLOYER_PRINCIPAL_ID'
$deployerPrincipalType = Get-EnvironmentValue -Name 'DEPLOYER_PRINCIPAL_TYPE'
$upstreamRepository = Get-EnvironmentValue -Name 'DEFENDER_REPORTING_REPO'
$upstreamRef = Get-EnvironmentValue -Name 'DEFENDER_REPORTING_REF'
$upstreamPath = Get-EnvironmentValue -Name 'DEFENDER_REPORTING_PATH'

if ($CheckUpstreamPath -and -not [string]::IsNullOrWhiteSpace($upstreamPath)) {
    $fullPath = [System.IO.Path]::GetFullPath($upstreamPath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "DEFENDER_REPORTING_PATH does not exist: $fullPath"
    }
}

$azdPath = (Get-Command -Name 'azd' -ErrorAction SilentlyContinue)?.Source
$azPath = (Get-Command -Name 'az' -ErrorAction SilentlyContinue)?.Source

Write-Output "[$CommandName] Wrapper environment contract"
Write-Output "  Repo root: $repoRoot"
Write-Output "  Compute kind: $($mode.ComputeKind)"
Write-Output "  Web kind: $($mode.WebKind)"
Write-Output "  Requested package mode: $($mode.RequestedPackageMode)"
Write-Output "  Effective package mode: $($mode.EffectivePackageMode)"
Write-Output "  Skip hosted auth setup: $resolvedSkipHostedAuthSetup"
Write-Output "  Hosted auth security group: $(if ([string]::IsNullOrWhiteSpace($hostedAuthSecurityGroup)) { '<not set>' } else { $hostedAuthSecurityGroup })"
Write-Output "  Upstream repo: $upstreamRepository"
Write-Output "  Upstream ref: $upstreamRef"
Write-Output "  Upstream path override: $(if ([string]::IsNullOrWhiteSpace($upstreamPath)) { '<none>' } else { [System.IO.Path]::GetFullPath($upstreamPath) })"
Write-Output "  Deployer principal id: $(if ([string]::IsNullOrWhiteSpace($deployerPrincipalId)) { '<not set>' } else { $deployerPrincipalId })"
Write-Output "  Deployer principal type: $(if ([string]::IsNullOrWhiteSpace($deployerPrincipalType)) { '<not set>' } else { $deployerPrincipalType })"
Write-Output "  azd: $(if ($azdPath) { $azdPath } else { '<missing>' })"
Write-Output "  az: $(if ($azPath) { $azPath } else { '<missing>' })"

$shouldWarnAboutHostedAuth = $CommandName -in @('preprovision', 'publish-deployment', 'predeploy', 'postdeploy')
if ($shouldWarnAboutHostedAuth -and $mode.RequiresHostedSurface -and -not $resolvedSkipHostedAuthSetup -and [string]::IsNullOrWhiteSpace($hostedAuthSecurityGroup)) {
    Write-Warning 'Hosted publish now defaults to Entra Easy Auth. HOSTED_AUTH_SECURITY_GROUP is not set, so the wrapper will allow any authenticated user in the tenant unless you pass -SecurityGroup or set HOSTED_AUTH_SECURITY_GROUP. Use SKIP_HOSTED_AUTH_SETUP=true / -SkipAuthSetup only when you want to skip wrapper auth management entirely.'
}

Write-Output '  Publish RBAC note: template upload, package upload, and SAS generation use storage data-plane APIs. The signed-in principal or DEPLOYER_PRINCIPAL_ID needs Storage Blob Data Contributor on the wrapper storage account.'

[PSCustomObject]@{
    ComputeKind = $mode.ComputeKind
    WebKind = $mode.WebKind
    RequestedPackageMode = $mode.RequestedPackageMode
    EffectivePackageMode = $mode.EffectivePackageMode
    SkipHostedAuthSetup = $resolvedSkipHostedAuthSetup
    HostedAuthSecurityGroup = $hostedAuthSecurityGroup
    UpstreamRepository = $upstreamRepository
    UpstreamRef = $upstreamRef
    UpstreamPath = $upstreamPath
    DeployerPrincipalId = $deployerPrincipalId
    DeployerPrincipalType = $deployerPrincipalType
    AzdPath = $azdPath
    AzPath = $azPath
}
