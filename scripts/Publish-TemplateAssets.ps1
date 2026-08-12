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

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

$upstreamRepo = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') `
    -RepositoryUrl $RepositoryUrl `
    -Ref $Ref `
    -RepositoryPath $RepositoryPath

function Get-DefaultMetadataPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpstreamRepositoryPath
    )

    return Join-Path $UpstreamRepositoryPath '.local\artifacts\dashboard-templates\dashboard-templates.manifest.json'
}

function Assert-TemplatePublisherMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Metadata,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedStorageAccountName,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedContainerName
    )

    Assert-ObjectFields -InputObject $Metadata -FieldNames @(
        'generatedOnUtc',
        'publishScript',
        'storageAccountName',
        'containerName',
        'templatesPath',
        'templateFingerprint',
        'templateFileCount',
        'totalSizeBytes',
        'files'
    ) -Description 'Dashboard template publisher metadata'

    if ([string]$Metadata.storageAccountName -ne $ExpectedStorageAccountName -or [string]$Metadata.containerName -ne $ExpectedContainerName) {
        throw 'Dashboard template publisher metadata does not match the requested storage destination.'
    }
    if ([string]$Metadata.publishScript -ne 'build/Publish-DashboardTemplates.ps1') {
        throw "Unexpected dashboard template publisher '$($Metadata.publishScript)'."
    }
    if ([string]$Metadata.templateFingerprint -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Dashboard template fingerprint is not a SHA-256 value.'
    }

    $files = @($Metadata.files)
    if ($files.Count -ne [int64]$Metadata.templateFileCount) {
        throw "Dashboard template file count mismatch: metadata reports $($Metadata.templateFileCount), but contains $($files.Count) entries."
    }

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $totalSizeBytes = [int64]0
    foreach ($file in $files) {
        Assert-ObjectFields -InputObject $file -FieldNames @('path', 'sourcePath', 'sha256', 'contentType', 'sizeBytes') -Description 'Dashboard template file metadata'
        $relativePath = [string]$file.path
        if ($relativePath -match '(^[\\/])|(^|[\\/])\.\.([\\/]|$)|\\') {
            throw "Dashboard template path '$relativePath' is not a safe forward-slash relative path."
        }
        if (-not $paths.Add($relativePath)) {
            throw "Dashboard template path '$relativePath' is duplicated."
        }
        if ([string]$file.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw "Dashboard template '$relativePath' has an invalid SHA-256 value."
        }
        if ([int64]$file.sizeBytes -lt 0) {
            throw "Dashboard template '$relativePath' has an invalid size."
        }
        $totalSizeBytes += [int64]$file.sizeBytes
    }

    if ($totalSizeBytes -ne [int64]$Metadata.totalSizeBytes) {
        throw "Dashboard template total size mismatch: metadata reports $($Metadata.totalSizeBytes), but entries total $totalSizeBytes."
    }
}

$publishScript = [PSCustomObject]@{
    Path = Join-Path $upstreamRepo.ResolvedPath 'build\Publish-DashboardTemplates.ps1'
    Contract = 'build-layer-v1'
}
if (-not (Test-Path -LiteralPath $publishScript.Path -PathType Leaf)) {
    throw "Required upstream template publish script was not found: $($publishScript.Path)"
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
if (-not $supportsMetadataPath) {
    throw "Upstream template publisher does not implement the required -MetadataPath contract: $($publishScript.Path)"
}

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
    Assert-TemplatePublisherMetadata `
        -Metadata $publisherMetadata `
        -ExpectedStorageAccountName $StorageAccountName `
        -ExpectedContainerName 'templates'
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
