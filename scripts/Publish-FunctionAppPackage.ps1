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
        [Parameter(Mandatory = $true)]
        [object[]]$Output
    )

    return (($Output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        }
        else {
            [string]$_
        }
    }) -join [Environment]::NewLine).Trim()
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

function Invoke-FunctionAppZipDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$FunctionAppName
    )

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $deployOutput = @(az functionapp deployment source config-zip `
            --src $PackagePath `
            --name $FunctionAppName `
            --resource-group $ResourceGroupName `
            --output none 2>&1)

        $deployText = Get-TextFromProcessOutput -Output $deployOutput

        if (-not [string]::IsNullOrWhiteSpace($deployText)) {
            foreach ($line in ($deployText -split "`r?`n")) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                if ($line -match '^WARNING:\s*(.+)') {
                    Write-Output ("Deployment status: {0}" -f $Matches[1])
                }
                else {
                    Write-Output $line
                }
            }
        }

        if ($LASTEXITCODE -eq 0 -or $deployText -match 'Deployment was partially successful') {
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

        throw "Function App zip deployment failed for '$FunctionAppName' (attempt $attempt/$maxAttempts)."
    }

    throw "Function App zip deployment failed for '$FunctionAppName' after $maxAttempts attempt(s)."
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
    throw 'Azure CLI (az) is required for Function App zip deployment.'
}

Write-Output ("Deploying Function App package '{0}' to {1}/{2}..." -f $resolvedPackagePath, $ResourceGroupName, $FunctionAppName)
Invoke-FunctionAppZipDeploy -PackagePath $resolvedPackagePath -ResourceGroupName $ResourceGroupName -FunctionAppName $FunctionAppName

$result
