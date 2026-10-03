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

$candidate = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') -RepositoryUrl ([string]$lock.repository) -Ref $CandidateRef -ForceRemote
& (Join-Path $PSScriptRoot 'Validate-Repository.ps1') -UpstreamRepositoryPath $candidate.ResolvedPath -ValidateAllUpstreamContracts

if ($UpdateLock -and ($CandidateRef -ne [string]$lock.ref -or $candidate.Commit -ne [string]$lock.commit)) {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $archivePath = Join-Path $repoRoot 'vendor\defender-reporting-source.zip'
    $packageLockPath = Join-Path $repoRoot 'contracts\upstream-package.json'
    $functionPackagePath = Join-Path $repoRoot '.local\validation\function-app-package\defender-reporting-function-app.zip'
    $functionManifestPath = Join-Path $repoRoot '.local\validation\function-app-package\defender-reporting-function-app.manifest.json'
    if (-not (Test-Path -LiteralPath $functionPackagePath -PathType Leaf) -or -not (Test-Path -LiteralPath $functionManifestPath -PathType Leaf)) {
        throw 'Validated Function App package or build manifest is missing.'
    }
    $functionManifest = Get-Content -LiteralPath $functionManifestPath -Raw | ConvertFrom-Json
    $functionHash = (Get-FileHash -LiteralPath $functionPackagePath -Algorithm SHA256).Hash
    $functionSize = (Get-Item -LiteralPath $functionPackagePath).Length
    if ($functionHash -ne [string]$functionManifest.packageSha256 -or $functionSize -ne [long]$functionManifest.packageSizeBytes) {
        throw 'Validated Function App package does not match its build manifest.'
    }
    $stagedArchive = Join-Path $repoRoot '.local\upstream\candidate-source.zip'
    & git -C $candidate.ResolvedPath archive --format=zip --output $stagedArchive $candidate.Commit
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stagedArchive -PathType Leaf)) {
        throw 'Could not archive the validated upstream source commit.'
    }
    $archiveHash = (Get-FileHash -LiteralPath $stagedArchive -Algorithm SHA256).Hash
    $archiveSize = (Get-Item -LiteralPath $stagedArchive).Length
    $packageLock = [ordered]@{
        schemaVersion = 1
        sourceCommit = [string]$candidate.Commit
        archivePath = 'vendor/defender-reporting-source.zip'
        archiveSha256 = $archiveHash
        archiveSizeBytes = $archiveSize
    }
    Copy-Item -LiteralPath $stagedArchive -Destination $archivePath -Force
    Copy-Item -LiteralPath $functionPackagePath -Destination (Join-Path $repoRoot 'vendor\function-app-package.zip') -Force
    $releasedFunctionLock = [ordered]@{
        schemaVersion = 1
        sourceCommit = [string]$candidate.Commit
        packagePath = 'vendor/function-app-package.zip'
        packageSha256 = $functionHash
        packageSizeBytes = $functionSize
        functionAppEntryPointFingerprint = [string]$functionManifest.functionAppEntryPointFingerprint
        sharedHelpersFingerprint = [string]$functionManifest.sharedHelpersFingerprint
        stagedAzAccountsModule = $functionManifest.stagedAzAccountsModule
    }
    $lock.ref = $CandidateRef
    $lock.commit = $candidate.Commit
    $lock.validatedOnUtc = [datetime]::UtcNow.ToString('o')
    $packageLock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $packageLockPath -Encoding utf8
    $releasedFunctionLock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $repoRoot 'contracts\released-function-app.json') -Encoding utf8
    $lock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lockPath -Encoding utf8
}

[PSCustomObject]@{
    CandidateRef = $CandidateRef
    CandidateCommit = $candidate.Commit
    CurrentRef = [string]$lock.ref
    Updated = [bool]($UpdateLock -and $CandidateRef -eq [string]$lock.ref -and $candidate.Commit -eq [string]$lock.commit)
}
