#Requires -Version 7.6
# Operator-only adaptation of azd-reference 59522c4 Assert-SecurityAzureTarget.
# No runtime dependency or hosted-workload permission change.
function Initialize-PublishTarget {
    param([string]$SubscriptionId, [string]$TenantId)
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $SubscriptionId = Get-EnvironmentValue 'AZURE_SUBSCRIPTION_ID' }
    if ([string]::IsNullOrWhiteSpace($TenantId)) { $TenantId = Get-EnvironmentValue 'AZURE_TENANT_ID' }
    foreach ($value in @($SubscriptionId, $TenantId)) {
        $parsed = [guid]::Empty
        if ($value -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or
            -not [guid]::TryParseExact($value, 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) {
            throw 'Explicit nonempty subscription and expected tenant GUIDs are required.'
        }
    }
    $script:PublishTarget = [pscustomobject]@{ SubscriptionId = $SubscriptionId; TenantId = $TenantId }
    Assert-PublishTarget
}

function Get-PublishTokenResponse {
    param([Parameter(Mandatory)][string]$Resource, [switch]$Graph)
    try {
        $arguments = @('account', 'get-access-token', '--resource', $Resource, '--output', 'json', '--only-show-errors')
        # CLI --tenant and --subscription are mutually exclusive. Graph is tenant-bound.
        if ($Graph) { $arguments += @('--tenant', $script:PublishTarget.TenantId) }
        else { $arguments += @('--subscription', $script:PublishTarget.SubscriptionId) }
        $raw = & az @arguments 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Token acquisition failed.' }
        $response = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
        if ($response.tenant -isnot [string] -or $response.tenant -ine $script:PublishTarget.TenantId -or
            (-not $Graph -and ($response.subscription -isnot [string] -or $response.subscription -ine $script:PublishTarget.SubscriptionId)) -or
            $response.accessToken -isnot [string] -or [string]::IsNullOrWhiteSpace($response.accessToken)) { throw 'Token metadata mismatch.' }
        return $response
    } catch { throw 'Could not acquire a token matching the explicit Azure target. Use normal browser or broker authentication.' }
}

function Assert-PublishTarget {
    if (-not (Get-Variable PublishTarget -Scope Script -ErrorAction SilentlyContinue)) { throw 'Initialize an explicit publisher target before Azure access.' }
    try {
        $target = $script:PublishTarget
        $raw = & az account show --subscription $target.SubscriptionId --output json --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Account lookup failed.' }
        $account = ($raw -join "`n") | ConvertFrom-Json -ErrorAction Stop
        if ($account.id -isnot [string] -or $account.id -ine $target.SubscriptionId -or
            $account.tenantId -isnot [string] -or $account.tenantId -ine $target.TenantId -or
            $account.environmentName -cne 'AzureCloud') { throw 'Account mismatch.' }
        $token = Get-PublishTokenResponse -Resource 'https://management.azure.com/'
        # Always fresh, including on cache hits. Cached CLI account state is not evidence.
        $subscription = Invoke-RestMethod -Method Get -Uri "https://management.azure.com/subscriptions/$($target.SubscriptionId)?api-version=2022-12-01" `
            -Headers @{ Authorization = "Bearer $($token.accessToken)" } -MaximumRedirection 0 -TimeoutSec 30
        if ($subscription.id -isnot [string] -or $subscription.id -ine "/subscriptions/$($target.SubscriptionId)" -or
            $subscription.subscriptionId -isnot [string] -or $subscription.subscriptionId -ine $target.SubscriptionId -or
            $subscription.tenantId -isnot [string] -or $subscription.tenantId -ine $target.TenantId -or
            $subscription.state -isnot [string] -or $subscription.state -cne 'Enabled') { throw 'Subscription mismatch or not Enabled.' }
    } catch { throw 'Unable to verify the explicit Azure public-cloud target and current Enabled subscription state.' }
}

function Assert-PublishResourceId {
    param($Resource, [string]$ResourceGroupName, [string]$ResourceType, [string]$Name)
    if ($ResourceGroupName -cnotmatch '\A[A-Za-z0-9_().-]{1,90}\z' -or $ResourceGroupName.EndsWith('.') -or
        $Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9-]{0,62}\z') { throw 'An exact resource group and resource name are required.' }
    $expected = "/subscriptions/$($script:PublishTarget.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/$ResourceType/$Name"
    if ($null -eq $Resource -or $Resource.id -isnot [string] -or $Resource.id -ine $expected) { throw 'Discovered resource does not match the approved resource binding.' }
}

function Assert-PublishStorage {
    param([string]$StorageAccountName, [string]$ResourceGroupName)
    if ($StorageAccountName -cnotmatch '\A[a-z0-9]{3,24}\z') { throw 'Invalid storage account name.' }
    if (-not $ResourceGroupName) { $ResourceGroupName = Resolve-ResourceGroupNameFromResource -ResourceName $StorageAccountName -ResourceType 'Microsoft.Storage/storageAccounts' }
    $resource = Get-AzCliJson -Arguments @('resource', 'show', '--resource-group', $ResourceGroupName, '--resource-type', 'Microsoft.Storage/storageAccounts', '--name', $StorageAccountName, '--output', 'json')
    Assert-PublishResourceId -Resource $resource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.Storage/storageAccounts' -Name $StorageAccountName
    if ($resource.properties.primaryEndpoints.blob -cne "https://$StorageAccountName.blob.core.windows.net/") { throw 'Storage endpoint does not match the approved account.' }
}

function Assert-PublishRequestUri {
    param([uri]$Uri)
    if ($Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment) { throw 'Only public-cloud HTTPS endpoints are supported.' }
    if ($Uri.Host -eq 'management.azure.com') {
        if (-not $Uri.AbsolutePath.StartsWith("/subscriptions/$($script:PublishTarget.SubscriptionId)/", [StringComparison]::OrdinalIgnoreCase)) { throw 'ARM request is outside the approved subscription.' }
    } elseif ($Uri.Host -eq 'graph.microsoft.com') {
        if ($Uri.AbsolutePath -notmatch '^/v1\.0/') { throw 'Unsupported Graph endpoint.' }
    } elseif ($Uri.Host -notmatch '\A[a-z0-9]{3,24}\.blob\.core\.windows\.net\z') { throw 'Unsupported Azure token destination.' }
}
