#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$CacheRoot = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) '.local\upstream'),
    [switch]$UseExistingCacheOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

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

$compatibilityLock = Get-UpstreamCompatibilityLock
$RepositoryUrl = if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) { [string]$compatibilityLock.repository } else { $RepositoryUrl }
$Ref = if ([string]::IsNullOrWhiteSpace($Ref)) { [string]$compatibilityLock.ref } else { $Ref }

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
        MatchesCompatibilityLock = ($commit -eq [string]$compatibilityLock.commit)
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
if ($RepositoryUrl -eq [string]$compatibilityLock.repository -and $Ref -eq [string]$compatibilityLock.ref -and $headCommit -ne [string]$compatibilityLock.commit) {
    throw "Upstream ref '$Ref' resolved to '$headCommit', but the compatibility lock requires '$($compatibilityLock.commit)'."
}

[PSCustomObject]@{
    RepositoryUrl = $RepositoryUrl
    Ref = $Ref
    ResolvedPath = $cachePath
    Commit = $headCommit
    Source = 'local-cache'
    MatchesCompatibilityLock = ($headCommit -eq [string]$compatibilityLock.commit)
}
