#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$FunctionAppName,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [string]$OutputPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) '.local\artifacts\function-app-package\defender-reporting-function-app.zip'),
    [string]$MetadataPath,
    [switch]$BuildOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredManifestFields = @(
    'packagePath',
    'packageSha256',
    'packageSizeBytes',
    'functionAppEntryPointFingerprint',
    'sharedHelpersFingerprint',
    'stagedAzAccountsModule'
)

$releasedPackageFileName = 'released-package.zip'

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
        [string]$PackagePath
    )

    $directory = Split-Path -Path $PackagePath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($PackagePath)
    return Join-Path $directory ($baseName + '.manifest.json')
}

function Get-TextFromProcessOutput {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Output = @()
    )

    if ($null -eq $Output -or $Output.Count -eq 0) {
        return ''
    }

    return (($Output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        }
        else {
            [string]$_
        }
    }) -join [Environment]::NewLine).Trim()
}

function Get-AzCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $commandOutput = @(az @Arguments 2>&1)
    $commandText = Get-TextFromProcessOutput -Output $commandOutput
    if ($LASTEXITCODE -ne 0) {
        throw $commandText
    }

    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return $null
    }

    return $commandText | ConvertFrom-Json
}

function Assert-ManifestField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Manifest,
        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    if (-not $Manifest.PSObject.Properties.Match($FieldName)) {
        throw "Upstream manifest is missing required field '$FieldName'."
    }

    $value = $Manifest.$FieldName
    if (($null -eq $value) -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "Upstream manifest field '$FieldName' is empty."
    }
}

function Get-FunctionAppDeploymentStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$FunctionAppName
    )

    $resource = Get-AzCliJson -Arguments @(
        'resource', 'show',
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.Web/sites',
        '--name', $FunctionAppName,
        '--api-version', '2024-04-01',
        '--query', '{deploymentContainerUrl:properties.functionAppConfig.deployment.storage.value}',
        '--output', 'json'
    )

    if ($null -eq $resource -or [string]::IsNullOrWhiteSpace([string]$resource.deploymentContainerUrl)) {
        throw "Function App '$FunctionAppName' does not expose functionAppConfig.deployment.storage.value. The Flex Consumption deployment container is missing."
    }

    $deploymentContainerUri = [System.Uri]::new([string]$resource.deploymentContainerUrl)
    $storageAccountName = $deploymentContainerUri.Host.Split('.')[0]
    $containerName = $deploymentContainerUri.AbsolutePath.Trim('/')

    if ([string]::IsNullOrWhiteSpace($storageAccountName) -or [string]::IsNullOrWhiteSpace($containerName)) {
        throw "Unable to parse the Flex Consumption deployment container from '$($deploymentContainerUri.AbsoluteUri)'."
    }

    return [PSCustomObject]@{
        StorageAccountName = $storageAccountName
        ContainerName = $containerName
        ContainerUri = ('{0}://{1}/{2}' -f $deploymentContainerUri.Scheme, $deploymentContainerUri.Host, $containerName)
    }
}

function Stage-ReleasedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePackagePath
    )

    $stagedPackagePath = Join-Path (Split-Path -Path $SourcePackagePath -Parent) $releasedPackageFileName
    if ((Resolve-AbsolutePath -Path $SourcePackagePath) -ne (Resolve-AbsolutePath -Path $stagedPackagePath)) {
        Copy-Item -LiteralPath $SourcePackagePath -Destination $stagedPackagePath -Force
    }

    return $stagedPackagePath
}

function Publish-ReleasedPackageBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageAccountName,
        [Parameter(Mandatory = $true)]
        [string]$ContainerName,
        [Parameter(Mandatory = $true)]
        [string]$ContainerUri,
        [Parameter(Mandatory = $true)]
        [string]$PackagePath
    )

    $uploadOutput = @(az storage blob upload `
        --auth-mode login `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $releasedPackageFileName `
        --file $PackagePath `
        --overwrite true `
        --only-show-errors `
        --output none 2>&1)

    $uploadText = Get-TextFromProcessOutput -Output $uploadOutput
    if ($LASTEXITCODE -ne 0) {
        throw "Uploading '$releasedPackageFileName' to deployment storage failed. Ensure the signed-in principal has blob data access to '$StorageAccountName'. $uploadText"
    }

    $sasExpiry = (Get-Date).ToUniversalTime().AddHours(2).ToString('yyyy-MM-ddTHH:mmZ')
    $sasOutput = @(az storage blob generate-sas `
        --auth-mode login `
        --as-user `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $releasedPackageFileName `
        --permissions r `
        --expiry $sasExpiry `
        --https-only `
        --output tsv 2>&1)

    $sasToken = Get-TextFromProcessOutput -Output $sasOutput
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sasToken)) {
        throw "Generating a read-only SAS for '$releasedPackageFileName' failed. Ensure the signed-in principal has blob data access to '$StorageAccountName'. $sasToken"
    }

    return ('{0}/{1}?{2}' -f $ContainerUri.TrimEnd('/'), $releasedPackageFileName, $sasToken.TrimStart('?'))
}

function Invoke-FunctionAppOneDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageUri,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$FunctionAppName
    )

    $operationToken = [System.Guid]::NewGuid().ToString('N')
    $templatePath = Join-Path ([System.IO.Path]::GetTempPath()) ('onedeploy-{0}.bicep' -f $operationToken)
    $parametersPath = Join-Path ([System.IO.Path]::GetTempPath()) ('onedeploy-{0}.parameters.json' -f $operationToken)
    @'
targetScope = 'resourceGroup'

param functionAppName string
param packageUri string

resource oneDeploy 'Microsoft.Web/sites/extensions@2022-09-01' = {
  name: '${functionAppName}/onedeploy'
  properties: {
    packageUri: packageUri
    type: 'zip'
    async: false
    restart: true
    clean: true
  }
}
'@ | Set-Content -LiteralPath $templatePath -Encoding utf8

    @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            functionAppName = @{
                value = $FunctionAppName
            }
            packageUri = @{
                value = $PackageUri
            }
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $parametersPath -Encoding utf8

    $maxAttempts = 5
    try {
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $deploymentName = 'onedeploy-{0}-{1}' -f $FunctionAppName, $attempt
            $deployOutput = @(az deployment group create `
                --resource-group $ResourceGroupName `
                --name $deploymentName `
                --template-file $templatePath `
                --parameters "@$parametersPath" `
                --only-show-errors `
                --output none 2>&1)

            $deployText = Get-TextFromProcessOutput -Output $deployOutput
            if (-not [string]::IsNullOrWhiteSpace($deployText)) {
                foreach ($line in ($deployText -split "`r?`n")) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        Write-Output $line
                    }
                }
            }

            if ($LASTEXITCODE -eq 0) {
                return
            }

            if ($attempt -lt $maxAttempts -and $deployText -match 'BadGatewayConnection|Bad Gateway') {
                Start-Sleep -Seconds (5 * $attempt)
                continue
            }

            if ($attempt -lt $maxAttempts -and $deployText -match 'InaccessibleStorageException|BlobUploadFailed|403|inaccessible') {
                Start-Sleep -Seconds (60 * $attempt)
                continue
            }

            if ($attempt -lt $maxAttempts -and $deployText -match 'another deployment is in progress|Deployment was cancelled and another deployment is in progress') {
                Start-Sleep -Seconds (20 * $attempt)
                continue
            }

            throw "Function App OneDeploy failed for '$FunctionAppName' (attempt $attempt/$maxAttempts)."
        }
    }
    finally {
        Remove-Item -LiteralPath $templatePath -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $parametersPath -ErrorAction SilentlyContinue
    }

    throw "Function App OneDeploy failed for '$FunctionAppName' after $maxAttempts attempt(s)."
}

$resolvedOutputPath = Resolve-AbsolutePath -Path $OutputPath
$resolvedMetadataPath = if ([string]::IsNullOrWhiteSpace($MetadataPath)) {
    Get-DefaultMetadataPath -PackagePath $resolvedOutputPath
}
else {
    Resolve-AbsolutePath -Path $MetadataPath
}

$upstreamRepo = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') `
    -RepositoryUrl $RepositoryUrl `
    -Ref $Ref `
    -RepositoryPath $RepositoryPath

$buildScriptPath = Join-Path $upstreamRepo.ResolvedPath 'build\Build-FunctionAppPackage.ps1'
if (-not (Test-Path -LiteralPath $buildScriptPath -PathType Leaf)) {
    throw "Required upstream package script was not found: $buildScriptPath"
}

Write-Output ("Resolved upstream repo: {0} ({1})" -f $upstreamRepo.ResolvedPath, $upstreamRepo.Commit)
Write-Output ("Building Function App package with upstream script: {0}" -f $buildScriptPath)

New-Item -Path (Split-Path -Path $resolvedOutputPath -Parent) -ItemType Directory -Force | Out-Null
New-Item -Path (Split-Path -Path $resolvedMetadataPath -Parent) -ItemType Directory -Force | Out-Null

& $buildScriptPath -OutputPath $resolvedOutputPath -MetadataPath $resolvedMetadataPath

if (-not (Test-Path -LiteralPath $resolvedMetadataPath -PathType Leaf)) {
    throw "Upstream package manifest was not created: $resolvedMetadataPath"
}

$manifest = Get-Content -LiteralPath $resolvedMetadataPath -Raw | ConvertFrom-Json
foreach ($field in $requiredManifestFields) {
    Assert-ManifestField -Manifest $manifest -FieldName $field
}

$resolvedPackagePath = Resolve-AbsolutePath -Path ([string]$manifest.packagePath)
if (-not (Test-Path -LiteralPath $resolvedPackagePath -PathType Leaf)) {
    throw "Manifest packagePath does not exist: $resolvedPackagePath"
}

$actualHash = (Get-FileHash -LiteralPath $resolvedPackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedHash = ([string]$manifest.packageSha256).ToLowerInvariant()
if ($actualHash -ne $expectedHash) {
    throw "Manifest packageSha256 does not match the built package at '$resolvedPackagePath'."
}

$packageInfo = Get-Item -LiteralPath $resolvedPackagePath
if ([int64]$manifest.packageSizeBytes -ne $packageInfo.Length) {
    throw "Manifest packageSizeBytes does not match the built package at '$resolvedPackagePath'."
}

$result = [PSCustomObject]@{
    UpstreamRepositoryPath = $upstreamRepo.ResolvedPath
    UpstreamCommit = $upstreamRepo.Commit
    PackagePath = $resolvedPackagePath
    ManifestPath = $resolvedMetadataPath
    PackageSha256 = $manifest.packageSha256
    PackageSizeBytes = $manifest.packageSizeBytes
    FunctionAppEntryPointFingerprint = $manifest.functionAppEntryPointFingerprint
    SharedHelpersFingerprint = $manifest.sharedHelpersFingerprint
}

if ($BuildOnly) {
    $result
    return
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($FunctionAppName)) {
    throw 'ResourceGroupName and FunctionAppName are required unless -BuildOnly is specified.'
}

if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for Function App OneDeploy.'
}

$releasedPackagePath = Stage-ReleasedPackage -SourcePackagePath $resolvedPackagePath
$deploymentStorage = Get-FunctionAppDeploymentStorage -ResourceGroupName $ResourceGroupName -FunctionAppName $FunctionAppName
$packageUri = Publish-ReleasedPackageBlob `
    -StorageAccountName $deploymentStorage.StorageAccountName `
    -ContainerName $deploymentStorage.ContainerName `
    -ContainerUri $deploymentStorage.ContainerUri `
    -PackagePath $releasedPackagePath

Write-Output ("Deploying Function App package '{0}' to {1}/{2} with OneDeploy..." -f $releasedPackagePath, $ResourceGroupName, $FunctionAppName)
Invoke-FunctionAppOneDeploy -PackageUri $packageUri -ResourceGroupName $ResourceGroupName -FunctionAppName $FunctionAppName

$result | Add-Member -NotePropertyName ReleasedPackagePath -NotePropertyValue $releasedPackagePath
$result | Add-Member -NotePropertyName PackageUri -NotePropertyValue $packageUri

$result
