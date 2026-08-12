#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ComputeKind,
    [string]$WebKind,
    [string]$DashboardPackageMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

function Get-ConfigurationValue {
    [CmdletBinding()]
    param(
        [string]$ExplicitValue,
        [Parameter(Mandatory = $true)]
        [string]$ResolvedName,
        [Parameter(Mandatory = $true)]
        [string]$RawName
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitValue)) {
        return $ExplicitValue
    }

    $processResolved = [Environment]::GetEnvironmentVariable($ResolvedName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($processResolved)) {
        return $processResolved
    }

    $azdValues = Get-AzdEnvironmentValues
    if ($azdValues.ContainsKey($ResolvedName) -and -not [string]::IsNullOrWhiteSpace([string]$azdValues[$ResolvedName])) {
        return [string]$azdValues[$ResolvedName]
    }

    $processRaw = [Environment]::GetEnvironmentVariable($RawName, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($processRaw)) {
        return $processRaw
    }

    if ($azdValues.ContainsKey($RawName) -and -not [string]::IsNullOrWhiteSpace([string]$azdValues[$RawName])) {
        return [string]$azdValues[$RawName]
    }

    return $null
}

$effectiveComputeKind = Get-ConfigurationValue -ExplicitValue $ComputeKind -ResolvedName 'computeKindResolved' -RawName 'COMPUTE_KIND'
$effectiveWebKind = Get-ConfigurationValue -ExplicitValue $WebKind -ResolvedName 'webKindResolved' -RawName 'WEB_KIND'
$effectivePackageMode = Get-ConfigurationValue -ExplicitValue $DashboardPackageMode -ResolvedName 'dashboardPackageModeResolved' -RawName 'DASHBOARD_PACKAGE_MODE'

$resolvedComputeKind = if ([string]::IsNullOrWhiteSpace($effectiveComputeKind)) { 'functionapp' } else { $effectiveComputeKind.Trim().ToLowerInvariant() }
$resolvedWebKind = if ([string]::IsNullOrWhiteSpace($effectiveWebKind)) { 'containerapp' } else { $effectiveWebKind.Trim().ToLowerInvariant() }
$requestedPackageMode = if ([string]::IsNullOrWhiteSpace($effectivePackageMode)) { 'auto' } else { $effectivePackageMode.Trim().ToLowerInvariant() }

$allowedComputeKinds = @('functionapp', 'automation')
$allowedWebKinds = @('containerapp', 'none')
$allowedPackageModes = @('auto', 'hosted', 'selfcontained', 'dual')

if ($resolvedComputeKind -notin $allowedComputeKinds) {
    throw "COMPUTE_KIND must be one of: $($allowedComputeKinds -join ', '). Received '$resolvedComputeKind'."
}

if ($resolvedWebKind -notin $allowedWebKinds) {
    throw "WEB_KIND must be one of: $($allowedWebKinds -join ', '). Received '$resolvedWebKind'."
}

if ($requestedPackageMode -notin $allowedPackageModes) {
    throw "DASHBOARD_PACKAGE_MODE must be one of: $($allowedPackageModes -join ', '). Received '$requestedPackageMode'."
}

$effectivePackageMode = switch ($requestedPackageMode) {
    'auto' {
        if ($resolvedWebKind -eq 'containerapp') { 'hosted' } else { 'selfcontained' }
        break
    }
    default {
        $requestedPackageMode
        break
    }
}

if (($resolvedWebKind -eq 'none') -and ($effectivePackageMode -eq 'hosted')) {
    throw "WEB_KIND=none cannot be combined with a hosted dashboard package."
}

[PSCustomObject]@{
    ComputeKind = $resolvedComputeKind
    WebKind = $resolvedWebKind
    RequestedPackageMode = $requestedPackageMode
    EffectivePackageMode = $effectivePackageMode
    RequiresFunctionAppPublish = ($resolvedComputeKind -eq 'functionapp')
    RequiresAutomationPublish = ($resolvedComputeKind -eq 'automation')
    RequiresHostedSurface = ($resolvedWebKind -eq 'containerapp')
}
