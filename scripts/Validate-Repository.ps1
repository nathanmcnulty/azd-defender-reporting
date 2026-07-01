#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$UpstreamRepositoryPath,
    [switch]$ValidateFunctionAppPackage,
    [switch]$ValidateAutomationRunbook
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$repoRoot = Split-Path -Path $scriptRoot -Parent

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

Write-Output 'Validation succeeded.'
