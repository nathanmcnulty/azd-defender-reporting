#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$UpstreamRepositoryPath,
    [switch]$ValidateFunctionAppPackage,
    [switch]$ValidateAutomationRunbook,
    [switch]$ValidateTemplatePublisher,
    [switch]$ValidateHostedAssets,
    [switch]$ValidateAllUpstreamContracts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$repoRoot = Split-Path -Path $scriptRoot -Parent

. (Join-Path $scriptRoot 'Common-AzurePublish.ps1')

if ($ValidateAllUpstreamContracts) {
    $ValidateFunctionAppPackage = $true
    $ValidateAutomationRunbook = $true
    $ValidateTemplatePublisher = $true
    $ValidateHostedAssets = $true
}

$compatibilityLock = Get-UpstreamCompatibilityLock
$hostedAssetsContract = Get-HostedAssetsContract

Write-Output 'Validating wrapper environment defaults...'
& (Join-Path $scriptRoot 'Validate-Environment.ps1') -ApplyDefaults -CommandName 'validate-repository' | Out-Null

Write-Output 'Parsing PowerShell scripts...'
$parseErrors = [System.Collections.Generic.List[object]]::new()
$scripts = Get-ChildItem -Path $scriptRoot -Filter '*.ps1' -File -Recurse | Sort-Object -Property FullName

foreach ($script in $scripts) {
    $null = $null
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        foreach ($error in $errors) {
            $parseErrors.Add([PSCustomObject]@{
                File = $script.FullName
                Message = $error.Message
            }) | Out-Null
        }
    }
}

if ($parseErrors.Count -gt 0) {
    $messages = $parseErrors | ForEach-Object { "$($_.File): $($_.Message)" }
    throw "PowerShell parsing failed:`n$($messages -join [Environment]::NewLine)"
}

Write-Output 'Compiling Bicep...'
$buildOutputRoot = Join-Path $repoRoot '.local\validation\bicep'
New-Item -Path $buildOutputRoot -ItemType Directory -Force | Out-Null

& az bicep build --file (Join-Path $repoRoot 'infra\main.bicep') --outdir $buildOutputRoot
if ($LASTEXITCODE -ne 0) {
    throw 'az bicep build failed.'
}

if ($ValidateFunctionAppPackage) {
    Write-Output 'Validating upstream Function App package contract...'
    $packageOutputPath = Join-Path $repoRoot '.local\validation\function-app-package\defender-reporting-function-app.zip'
    & (Join-Path $scriptRoot 'Publish-FunctionAppPackage.ps1') `
        -RepositoryPath $UpstreamRepositoryPath `
        -OutputPath $packageOutputPath `
        -BuildOnly | Out-Null
}

if ($ValidateAutomationRunbook) {
    Write-Output 'Validating upstream Automation runbook contract...'
    & (Join-Path $scriptRoot 'Publish-AutomationRunbook.ps1') `
        -RepositoryPath $UpstreamRepositoryPath `
        -BuildOnly | Out-Null
}

if ($ValidateTemplatePublisher) {
    Write-Output 'Validating upstream dashboard template publisher contract...'
    $upstreamRepo = & (Join-Path $scriptRoot 'Resolve-UpstreamRepo.ps1') -RepositoryPath $UpstreamRepositoryPath
    $publisherPath = Join-Path $upstreamRepo.ResolvedPath 'build\Publish-DashboardTemplates.ps1'
    if (-not (Test-Path -LiteralPath $publisherPath -PathType Leaf)) {
        throw "Required upstream template publisher was not found: $publisherPath"
    }
    $publisherCommand = Get-Command -Name $publisherPath -ErrorAction Stop
    foreach ($parameterName in @('StorageAccountName', 'ContainerName', 'TemplatesPath', 'MetadataPath')) {
        if (-not $publisherCommand.Parameters.ContainsKey($parameterName)) {
            throw "Upstream template publisher is missing parameter '$parameterName'."
        }
    }
}

if ($ValidateHostedAssets) {
    Write-Output 'Validating hosted asset contract against upstream generated-artifact tests...'
    $upstreamRepo = & (Join-Path $scriptRoot 'Resolve-UpstreamRepo.ps1') -RepositoryPath $UpstreamRepositoryPath
    $artifactTestPath = Join-Path $upstreamRepo.ResolvedPath 'tests\Validate-DashboardGeneratedArtifacts.js'
    if (-not (Test-Path -LiteralPath $artifactTestPath -PathType Leaf)) {
        throw "Required upstream hosted artifact test was not found: $artifactTestPath"
    }
    $artifactTestContent = Get-Content -LiteralPath $artifactTestPath -Raw
    $match = [regex]::Match($artifactTestContent, '(?s)const\s+hostedAssets\s*=\s*\[(?<paths>.*?)\];')
    if (-not $match.Success) {
        throw 'Unable to locate the upstream hostedAssets contract.'
    }
    $upstreamPaths = @([regex]::Matches($match.Groups['paths'].Value, "'(?<path>[^']+)'") | ForEach-Object { $_.Groups['path'].Value } | Sort-Object -Unique)
    $wrapperPaths = @($hostedAssetsContract.assets | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
    $pathDifferences = @(Compare-Object -ReferenceObject $wrapperPaths -DifferenceObject $upstreamPaths)
    if ($pathDifferences.Count -gt 0) {
        $details = $pathDifferences | ForEach-Object { "{0} ({1})" -f $_.InputObject, $_.SideIndicator }
        throw "Hosted asset contract differs from upstream hostedAssets:`n$($details -join [Environment]::NewLine)"
    }
}

if ([string]$compatibilityLock.commit -notmatch '^[a-fA-F0-9]{40}$') {
    throw 'Upstream compatibility lock commit is not a full Git SHA.'
}

Write-Output 'Validation succeeded.'
