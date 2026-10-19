#Requires -Version 7.6

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,
    [string]$ResourceGroupName,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [string]$TemplatesPath,
    [string]$MetadataPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

Initialize-PublishTarget -SubscriptionId $SubscriptionId -TenantId $TenantId
$SubscriptionId = $script:PublishTarget.SubscriptionId
$TenantId = $script:PublishTarget.TenantId


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

# Reuse locked upstream's offline template state contract, never its ambient
# authentication/publishing functions. The archive and its version remain unchanged.
. (Join-Path $upstreamRepo.ResolvedPath 'build/private/AzureArtifactBuildTools.ps1')
$resolvedTemplatesPath = Resolve-DashboardTemplatesPath -RepoRoot $upstreamRepo.ResolvedPath -TemplatesPath $TemplatesPath
$publishState = Get-DashboardTemplatePublishState -TemplatesPath $resolvedTemplatesPath -RepoRoot $upstreamRepo.ResolvedPath
$publisherMetadata = [pscustomobject]@{
    generatedOnUtc = [datetime]::UtcNow.ToString('o')
    publishScript = 'build/Publish-DashboardTemplates.ps1'
    storageAccountName = $StorageAccountName
    containerName = 'templates'
    templatesPath = $publishState.TemplatesDisplayPath
    templateFingerprint = $publishState.Fingerprint
    templateFileCount = $publishState.FileCount
    totalSizeBytes = $publishState.TotalSizeBytes
    files = @($publishState.Files | ForEach-Object {
        [pscustomobject]@{ path = $_.Path; sourcePath = $_.SourcePath; sha256 = $_.Sha256; contentType = $_.ContentType; sizeBytes = $_.SizeBytes }
    })
}
Assert-TemplatePublisherMetadata -Metadata $publisherMetadata -ExpectedStorageAccountName $StorageAccountName -ExpectedContainerName 'templates'
Assert-PublishStorage -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName
foreach ($file in $publishState.Files) {
    if ((Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256).Hash -ine $file.Sha256 -or
        (Get-Item -LiteralPath $file.FullPath).Length -ne $file.SizeBytes) { throw 'Template bytes changed after package validation.' }
    $blobPath = (@($file.Path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $uri = "https://$StorageAccountName.blob.core.windows.net/templates/$blobPath"
    $headers = @{
        Authorization = 'Bearer {0}' -f (Get-AzAccessToken -Url $uri)
        'x-ms-version' = '2023-11-03'
        'x-ms-date' = [datetime]::UtcNow.ToString('R')
        'x-ms-blob-type' = 'BlockBlob'
    }
    Assert-PublishTarget
    Invoke-WebRequest -Method Put -Uri $uri -Headers $headers -InFile $file.FullPath -ContentType $file.ContentType -MaximumRedirection 0 -TimeoutSec 120 | Out-Null
}
$publisherMetadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resolvedMetadataPath -Encoding utf8

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
