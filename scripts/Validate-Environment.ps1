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

Set-ProcessAndAzdDefault -Name 'COMPUTE_KIND' -Value 'functionapp'
Set-ProcessAndAzdDefault -Name 'WEB_KIND' -Value 'containerapp'
Set-ProcessAndAzdDefault -Name 'DASHBOARD_PACKAGE_MODE' -Value 'auto'
Set-ProcessAndAzdDefault -Name 'DEFENDER_REPORTING_REPO' -Value 'https://github.com/nathanmcnulty/defender-reporting.git'
Set-ProcessAndAzdDefault -Name 'DEFENDER_REPORTING_REF' -Value 'main'

$mode = & (Join-Path $scriptRoot 'Get-DeploymentMode.ps1')

if ($CheckUpstreamPath -and -not [string]::IsNullOrWhiteSpace($env:DEFENDER_REPORTING_PATH)) {
    $fullPath = [System.IO.Path]::GetFullPath($env:DEFENDER_REPORTING_PATH)
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
Write-Output "  Upstream repo: $($env:DEFENDER_REPORTING_REPO)"
Write-Output "  Upstream ref: $($env:DEFENDER_REPORTING_REF)"
Write-Output "  Upstream path override: $(if ([string]::IsNullOrWhiteSpace($env:DEFENDER_REPORTING_PATH)) { '<none>' } else { [System.IO.Path]::GetFullPath($env:DEFENDER_REPORTING_PATH) })"
Write-Output "  azd: $(if ($azdPath) { $azdPath } else { '<missing>' })"
Write-Output "  az: $(if ($azPath) { $azPath } else { '<missing>' })"

[PSCustomObject]@{
    ComputeKind = $mode.ComputeKind
    WebKind = $mode.WebKind
    RequestedPackageMode = $mode.RequestedPackageMode
    EffectivePackageMode = $mode.EffectivePackageMode
    UpstreamRepository = $env:DEFENDER_REPORTING_REPO
    UpstreamRef = $env:DEFENDER_REPORTING_REF
    UpstreamPath = $env:DEFENDER_REPORTING_PATH
    AzdPath = $azdPath
    AzPath = $azPath
}
