#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ContainerAppName,
    [string]$ResourceGroupName,
    [string]$StorageAccountName,
    [string]$SecurityGroup = $env:HOSTED_AUTH_SECURITY_GROUP,
    [string]$AppRegistrationDisplayName = $env:HOSTED_AUTH_APP_DISPLAY_NAME,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [switch]$PlanOnly,
    [switch]$SkipAuthSetup,
    [switch]$SkipTemplatePublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-BooleanEnvironmentValue {
    [CmdletBinding()]
    param(
        [string]$Value,
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'n' { return $false }
        'off' { return $false }
        default { throw "Unable to interpret boolean value '$Value'." }
    }
}

function Resolve-StorageAccountName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [string]$RequestedStorageAccountName
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedStorageAccountName)) {
        return $RequestedStorageAccountName
    }

    $storageAccounts = @(Get-AzCliJson -Arguments @(
        'resource', 'list',
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.Storage/storageAccounts',
        '--query', '[].name',
        '--output', 'json'
    ))

    if ($storageAccounts.Count -eq 0) {
        throw "No storage account resources were found in resource group '$ResourceGroupName'."
    }

    if ($storageAccounts.Count -gt 1) {
        throw "Multiple storage accounts were found in resource group '$ResourceGroupName'. Pass -StorageAccountName explicitly."
    }

    return [string]$storageAccounts[0]
}

function Invoke-HostedSurfaceProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [int[]]$ExpectedStatusCodes = @(200),
        [int]$MaxAttempts = 6
    )

    $lastStatusCode = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 0 -SkipHttpErrorCheck
            $lastStatusCode = [int]$response.StatusCode
        }
        catch {
            if ($null -ne $_.Exception.Response) {
                $lastStatusCode = [int]$_.Exception.Response.StatusCode
            }
            else {
                throw
            }
        }

        if ($lastStatusCode -in $ExpectedStatusCodes) {
            return $lastStatusCode
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds (10 * $attempt)
        }
    }

    throw "Hosted surface probe for '$Uri' returned status code '$lastStatusCode'. Expected one of: $($ExpectedStatusCodes -join ', ')."
}

$mode = & (Join-Path $PSScriptRoot 'Get-DeploymentMode.ps1')
if (-not $mode.RequiresHostedSurface) {
    throw 'WEB_KIND must be containerapp to publish or validate the hosted surface.'
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($ContainerAppName)) {
    throw 'ResourceGroupName and ContainerAppName are required.'
}

if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for hosted surface publish.'
}

$resolvedSkipAuthSetup = if ($PSBoundParameters.ContainsKey('SkipAuthSetup')) {
    [bool]$SkipAuthSetup
}
else {
    Resolve-BooleanEnvironmentValue -Value $env:SKIP_HOSTED_AUTH_SETUP -Default $false
}

$resolvedStorageAccountName = Resolve-StorageAccountName -ResourceGroupName $ResourceGroupName -RequestedStorageAccountName $StorageAccountName
$templatePublishResult = if ($SkipTemplatePublish) {
    [PSCustomObject]@{
        StorageAccountName = $resolvedStorageAccountName
        ContainerName = 'templates'
        PublisherContract = 'prepublished'
    }
}
else {
    @(& (Join-Path $PSScriptRoot 'Publish-TemplateAssets.ps1') `
        -StorageAccountName $resolvedStorageAccountName `
        -RepositoryPath $RepositoryPath `
        -RepositoryUrl $RepositoryUrl `
        -Ref $Ref) | Where-Object {
            $_ -is [psobject] -and $_.PSObject.Properties.Match('ContainerName').Count -gt 0
        } | Select-Object -Last 1
}

if ($null -eq $templatePublishResult) {
    throw 'Publish-TemplateAssets.ps1 did not return the expected template publish result.'
}

$containerApp = Get-AzCliJson -Arguments @(
    'resource', 'show',
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.App/containerApps',
    '--name', $ContainerAppName,
    '--query', '{fqdn:properties.configuration.ingress.fqdn,provisioningState:properties.provisioningState}',
    '--output', 'json'
)

if ($null -eq $containerApp -or [string]::IsNullOrWhiteSpace([string]$containerApp.fqdn)) {
    throw "Container App '$ContainerAppName' was not found in resource group '$ResourceGroupName' or does not expose an ingress FQDN."
}

$containerAppUrl = 'https://{0}' -f ([string]$containerApp.fqdn)
$result = [PSCustomObject]@{
    ContainerAppName = $ContainerAppName
    ResourceGroupName = $ResourceGroupName
    ContainerAppUrl = $containerAppUrl
    ProvisioningState = [string]$containerApp.provisioningState
    StorageAccountName = $resolvedStorageAccountName
    TemplatesContainerName = $templatePublishResult.ContainerName
    EffectivePackageMode = $mode.EffectivePackageMode
    SkipAuthSetup = $resolvedSkipAuthSetup
}

$authResult = & (Join-Path $PSScriptRoot 'Set-HostedSurfaceAuth.ps1') `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $ContainerAppName `
    -SecurityGroup $SecurityGroup `
    -AppRegistrationDisplayName $AppRegistrationDisplayName `
    -SkipAuthSetup:([bool]$resolvedSkipAuthSetup) `
    -PlanOnly:([bool]$PlanOnly)

$result | Add-Member -NotePropertyName AuthManagementMode -NotePropertyValue $authResult.AuthManagementMode
$result | Add-Member -NotePropertyName HostedAuthEnabled -NotePropertyValue ([bool]$authResult.CurrentAuthEnabled)
$result | Add-Member -NotePropertyName HostedAuthValidationExpectation -NotePropertyValue ([string]$authResult.ValidationExpectation)
$result | Add-Member -NotePropertyName HostedAuthSecurityGroupId -NotePropertyValue ([string]$authResult.SecurityGroupId)
$result | Add-Member -NotePropertyName HostedAuthSecurityGroupDisplayName -NotePropertyValue ([string]$authResult.SecurityGroupDisplayName)
$result | Add-Member -NotePropertyName HostedAuthAppRegistrationClientId -NotePropertyValue ([string]$authResult.AppRegistrationClientId)
$result | Add-Member -NotePropertyName HostedAuthAppRegistrationDisplayName -NotePropertyValue ([string]$authResult.AppRegistrationDisplayName)

if ($PlanOnly) {
    $result
    return
}

$expectedStatusCodes = switch ([string]$authResult.ValidationExpectation) {
    'RedirectOrAuthChallenge' { @(301, 302, 303, 307, 308, 401, 403) }
    'Anonymous200' { @(200) }
    default { @(200, 301, 302, 303, 307, 308, 401, 403) }
}

$statusCode = Invoke-HostedSurfaceProbe -Uri $containerAppUrl -ExpectedStatusCodes $expectedStatusCodes

$result | Add-Member -NotePropertyName HttpStatusCode -NotePropertyValue $statusCode
$result
