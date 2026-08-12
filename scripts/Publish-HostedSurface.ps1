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

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

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
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.AllowAutoRedirect = $false
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(30)
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
        $response = $null

        try {
            $response = $client.Send($request)
            $lastStatusCode = [int]$response.StatusCode
        }
        catch {
            if ($_.Exception.PSObject.Properties.Match('StatusCode').Count -gt 0 -and $null -ne $_.Exception.StatusCode) {
                $lastStatusCode = [int]$_.Exception.StatusCode
            }
            else {
                throw
            }
        }
        finally {
            if ($null -ne $response) {
                $response.Dispose()
            }

            $request.Dispose()
            $client.Dispose()
            $handler.Dispose()
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
    Resolve-BooleanString -Value (Get-EnvironmentValue -Name 'SKIP_HOSTED_AUTH_SETUP') -Default $false
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
$result | Add-Member -NotePropertyName HostedAuthAccessScope -NotePropertyValue ([string]$authResult.AuthAccessScope)
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
