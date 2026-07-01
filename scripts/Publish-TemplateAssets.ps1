#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [string]$TemplatesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$upstreamRepo = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') `
    -RepositoryUrl $RepositoryUrl `
    -Ref $Ref `
    -RepositoryPath $RepositoryPath

$uploadScriptPath = Join-Path $upstreamRepo.ResolvedPath 'azure\Upload-Templates.ps1'
if (-not (Test-Path -LiteralPath $uploadScriptPath -PathType Leaf)) {
    throw "Required upstream template upload script was not found: $uploadScriptPath"
}

$uploadParameters = @{
    StorageAccountName = $StorageAccountName
}

if (-not [string]::IsNullOrWhiteSpace($TemplatesPath)) {
    $uploadParameters.TemplatesPath = [System.IO.Path]::GetFullPath($TemplatesPath)
}

Write-Verbose ("Resolved upstream repo: {0} ({1})" -f $upstreamRepo.ResolvedPath, $upstreamRepo.Commit)
Write-Verbose ("Uploading template assets with upstream script: {0}" -f $uploadScriptPath)

& $uploadScriptPath @uploadParameters

[PSCustomObject]@{
    UpstreamRepositoryPath = $upstreamRepo.ResolvedPath
    UpstreamCommit = $upstreamRepo.Commit
    StorageAccountName = $StorageAccountName
    ContainerName = 'templates'
}
