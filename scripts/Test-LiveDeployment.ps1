#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    [string]$StorageAccountName,
    [string]$ContainerAppName,
    [string]$AccessToken,
    [int]$MaxAttempts = 12,
    [int]$DelaySeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')

function Test-DashboardBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountName,
        [Parameter(Mandatory = $true)]
        [string]$BlobName
    )

    $blob = Get-AzCliJson -Arguments @(
        'storage', 'blob', 'show',
        '--account-name', $AccountName,
        '--container-name', 'dashboards',
        '--name', $BlobName,
        '--auth-mode', 'login',
        '--output', 'json'
    )
    return ($null -ne $blob -and [int64]$blob.properties.contentLength -gt 0)
}

function Wait-ForDashboardBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountName,
        [Parameter(Mandatory = $true)]
        [string]$BlobName
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if (Test-DashboardBlob -AccountName $AccountName -BlobName $BlobName) {
                return
            }
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                throw
            }
        }
        Start-Sleep -Seconds $DelaySeconds
    }
    throw "Dashboard blob '$BlobName' was not available after $MaxAttempts attempts."
}

if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for live smoke testing.'
}

$mode = & (Join-Path $PSScriptRoot 'Get-DeploymentMode.ps1')
$assetContract = Get-HostedAssetsContract
$resolvedStorageAccountName = Resolve-StorageAccountName -ResourceGroupName $ResourceGroupName -RequestedStorageAccountName $StorageAccountName
$dashboardBlobName = if ($mode.EffectivePackageMode -in @('hosted', 'dual')) {
    [string]$assetContract.dashboardBlobNames.hosted
}
else {
    [string]$assetContract.dashboardBlobNames.selfContained
}

Wait-ForDashboardBlob -AccountName $resolvedStorageAccountName -BlobName $dashboardBlobName

if ($mode.EffectivePackageMode -in @('hosted', 'dual')) {
    foreach ($asset in @($assetContract.assets) | Where-Object { [bool]$_.required }) {
        $blobName = '{0}/{1}' -f $assetContract.hostedAssetsDirectory, $asset.path
        if (-not (Test-DashboardBlob -AccountName $resolvedStorageAccountName -BlobName $blobName)) {
            throw "Required hosted dashboard asset '$blobName' is missing or empty."
        }
    }
}

$result = [ordered]@{
    ResourceGroupName = $ResourceGroupName
    StorageAccountName = $resolvedStorageAccountName
    DashboardBlobName = $dashboardBlobName
    RequiredAssetCount = @($assetContract.assets | Where-Object { [bool]$_.required }).Count
}

if ($mode.RequiresHostedSurface) {
    $resolvedContainerAppName = if ([string]::IsNullOrWhiteSpace($ContainerAppName)) {
        Resolve-SingleResourceNameInGroup -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.App/containerApps' -FriendlyName 'Container App'
    }
    else {
        $ContainerAppName
    }
    $containerApp = Get-AzCliJson -Arguments @(
        'resource', 'show',
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.App/containerApps',
        '--name', $resolvedContainerAppName,
        '--query', '{fqdn:properties.configuration.ingress.fqdn}',
        '--output', 'json'
    )
    $uri = 'https://{0}' -f $containerApp.fqdn
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        $headers.Authorization = "Bearer $AccessToken"
    }
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $uri)
    $response = $null
    try {
        foreach ($header in $headers.GetEnumerator()) {
            $request.Headers.TryAddWithoutValidation([string]$header.Key, [string]$header.Value) | Out-Null
        }

        $response = $client.Send($request)
        $statusCode = [int]$response.StatusCode
        $responseContent = if ($null -eq $response.Content) { '' } else { $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }

        $request.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        if ($statusCode -notin @(200, 301, 302, 303, 307, 308, 401, 403)) {
            throw "Hosted surface returned unexpected HTTP status $statusCode."
        }
    }
    else {
        if ($statusCode -ne 200) {
            throw "Authenticated hosted surface returned HTTP status $statusCode."
        }
        if ($responseContent -match 'The dashboard has not been generated yet') {
            throw 'Authenticated hosted surface is still serving the placeholder dashboard.'
        }
    }
    $result.ContainerAppName = $resolvedContainerAppName
    $result.ContainerAppUrl = $uri
    $result.HttpStatusCode = $statusCode
}

[PSCustomObject]$result
