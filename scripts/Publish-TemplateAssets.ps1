#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [string]$TemplatesPath,
    [string]$MetadataPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$upstreamRepo = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') `
    -RepositoryUrl $RepositoryUrl `
    -Ref $Ref `
    -RepositoryPath $RepositoryPath

function Resolve-AbsolutePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

function Get-DefaultMetadataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpstreamRepositoryPath
    )

    return Join-Path $UpstreamRepositoryPath '.local\artifacts\dashboard-templates\dashboard-templates.manifest.json'
}

$publishScriptCandidates = @(
    [PSCustomObject]@{
        Path = Join-Path $upstreamRepo.ResolvedPath 'build\Publish-DashboardTemplates.ps1'
        Contract = 'build-layer'
    }
    [PSCustomObject]@{
        Path = Join-Path $upstreamRepo.ResolvedPath 'azure\Upload-Templates.ps1'
        Contract = 'azure-compat'
    }
)

$publishScript = $publishScriptCandidates |
    Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf } |
    Select-Object -First 1

if ($null -eq $publishScript) {
    $expectedPaths = $publishScriptCandidates | ForEach-Object { $_.Path }
    throw "Required upstream template publish script was not found. Expected one of: $($expectedPaths -join ', ')"
}

$uploadParameters = @{
    StorageAccountName = $StorageAccountName
}

if (-not [string]::IsNullOrWhiteSpace($TemplatesPath)) {
    $uploadParameters.TemplatesPath = [System.IO.Path]::GetFullPath($TemplatesPath)
}

$resolvedMetadataPath = $null
$publisherMetadata = $null
$publishScriptCommand = Get-Command -Name $publishScript.Path -ErrorAction Stop
$supportsMetadataPath = ($publishScriptCommand.Parameters.ContainsKey('MetadataPath'))

if ($supportsMetadataPath) {
    $resolvedMetadataPath = if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
        Get-DefaultMetadataPath -UpstreamRepositoryPath $upstreamRepo.ResolvedPath
    }
    else {
        Resolve-AbsolutePath -Path $MetadataPath
    }

    New-Item -Path (Split-Path -Path $resolvedMetadataPath -Parent) -ItemType Directory -Force | Out-Null
    if (Test-Path -LiteralPath $resolvedMetadataPath -PathType Leaf) {
        Remove-Item -LiteralPath $resolvedMetadataPath -Force
    }

    $uploadParameters.MetadataPath = $resolvedMetadataPath
}

Write-Verbose ("Resolved upstream repo: {0} ({1})" -f $upstreamRepo.ResolvedPath, $upstreamRepo.Commit)
Write-Verbose ("Uploading template assets with upstream script: {0}" -f $publishScript.Path)

& $publishScript.Path @uploadParameters

if ($supportsMetadataPath) {
    if (-not (Test-Path -LiteralPath $resolvedMetadataPath -PathType Leaf)) {
        throw "The upstream template publisher accepted -MetadataPath but did not create '$resolvedMetadataPath'."
    }

    $publisherMetadata = Get-Content -LiteralPath $resolvedMetadataPath -Raw | ConvertFrom-Json -Depth 20
}

[PSCustomObject]@{
    UpstreamRepositoryPath = $upstreamRepo.ResolvedPath
    UpstreamCommit = $upstreamRepo.Commit
    StorageAccountName = $StorageAccountName
    ContainerName = 'templates'
    PublisherPath = $publishScript.Path
    PublisherContract = $publishScript.Contract
    PublisherMetadataPath = $resolvedMetadataPath
    PublisherMetadata = $publisherMetadata
}
