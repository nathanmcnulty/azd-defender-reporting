#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ComputeKind = $env:COMPUTE_KIND,
    [string]$WebKind = $env:WEB_KIND,
    [string]$DashboardPackageMode = $env:DASHBOARD_PACKAGE_MODE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedComputeKind = if ([string]::IsNullOrWhiteSpace($ComputeKind)) { 'functionapp' } else { $ComputeKind.Trim().ToLowerInvariant() }
$resolvedWebKind = if ([string]::IsNullOrWhiteSpace($WebKind)) { 'containerapp' } else { $WebKind.Trim().ToLowerInvariant() }
$requestedPackageMode = if ([string]::IsNullOrWhiteSpace($DashboardPackageMode)) { 'auto' } else { $DashboardPackageMode.Trim().ToLowerInvariant() }

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

