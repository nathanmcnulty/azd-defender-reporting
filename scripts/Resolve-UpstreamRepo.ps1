#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepositoryUrl = $(if ([string]::IsNullOrWhiteSpace($env:DEFENDER_REPORTING_REPO)) { 'https://github.com/nathanmcnulty/defender-reporting.git' } else { $env:DEFENDER_REPORTING_REPO }),
    [string]$Ref = $(if ([string]::IsNullOrWhiteSpace($env:DEFENDER_REPORTING_REF)) { 'main' } else { $env:DEFENDER_REPORTING_REF }),
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$CacheRoot = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) '.local\upstream'),
    [switch]$UseExistingCacheOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed.`n$output"
    }

    return ($output | Out-String).Trim()
}

function Resolve-AbsolutePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

if ([string]::IsNullOrWhiteSpace($RepositoryPath) -eq $false) {
    $resolvedPath = Resolve-AbsolutePath -Path $RepositoryPath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw "DEFENDER_REPORTING_PATH does not exist: $resolvedPath"
    }

    $commit = Invoke-GitCommand -Arguments @('-C', $resolvedPath, 'rev-parse', 'HEAD')
    [PSCustomObject]@{
        RepositoryUrl = $RepositoryUrl
        Ref = $Ref
        ResolvedPath = $resolvedPath
        Commit = $commit
        Source = 'path-override'
    }
    return
}

$resolvedCacheRoot = Resolve-AbsolutePath -Path $CacheRoot
$cachePath = Join-Path $resolvedCacheRoot 'defender-reporting'

if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) {
    if ($UseExistingCacheOnly) {
        throw "Cached upstream repo not found at $cachePath and UseExistingCacheOnly was specified."
    }

    New-Item -Path $resolvedCacheRoot -ItemType Directory -Force | Out-Null
    Invoke-GitCommand -Arguments @('clone', '--quiet', '--filter=blob:none', '--no-checkout', $RepositoryUrl, $cachePath) | Out-Null
}

if (-not $UseExistingCacheOnly) {
    Invoke-GitCommand -Arguments @('-C', $cachePath, 'fetch', '--quiet', '--depth', '1', 'origin', $Ref) | Out-Null
    Invoke-GitCommand -Arguments @('-C', $cachePath, 'checkout', '--quiet', '--force', 'FETCH_HEAD') | Out-Null
}

$headCommit = Invoke-GitCommand -Arguments @('-C', $cachePath, 'rev-parse', 'HEAD')

[PSCustomObject]@{
    RepositoryUrl = $RepositoryUrl
    Ref = $Ref
    ResolvedPath = $cachePath
    Commit = $headCommit
    Source = 'local-cache'
}

