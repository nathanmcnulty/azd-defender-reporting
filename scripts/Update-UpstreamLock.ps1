#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$CandidateRef,
    [switch]$UpdateLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

$lockPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'contracts\upstream-lock.json'
$lock = Get-UpstreamCompatibilityLock -LockPath $lockPath

if ([string]::IsNullOrWhiteSpace($CandidateRef)) {
    $headers = @{ Accept = 'application/vnd.github+json' }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers.Authorization = "Bearer $env:GITHUB_TOKEN"
    }
    $latestRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/nathanmcnulty/defender-reporting/releases/latest' -Headers $headers
    $CandidateRef = [string]$latestRelease.tag_name
}

if ([string]::IsNullOrWhiteSpace($CandidateRef)) {
    throw 'Unable to resolve a candidate upstream release.'
}

$candidate = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') -RepositoryUrl ([string]$lock.repository) -Ref $CandidateRef
& (Join-Path $PSScriptRoot 'Validate-Repository.ps1') -UpstreamRepositoryPath $candidate.ResolvedPath -ValidateAllUpstreamContracts

if ($UpdateLock -and ($CandidateRef -ne [string]$lock.ref -or $candidate.Commit -ne [string]$lock.commit)) {
    $lock.ref = $CandidateRef
    $lock.commit = $candidate.Commit
    $lock.validatedOnUtc = [datetime]::UtcNow.ToString('o')
    $lock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lockPath -Encoding utf8
}

[PSCustomObject]@{
    CandidateRef = $CandidateRef
    CandidateCommit = $candidate.Commit
    CurrentRef = [string]$lock.ref
    Updated = [bool]($UpdateLock -and $CandidateRef -eq [string]$lock.ref -and $candidate.Commit -eq [string]$lock.commit)
}
