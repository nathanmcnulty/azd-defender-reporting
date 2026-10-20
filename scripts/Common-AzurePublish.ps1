#Requires -Version 7.6

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
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

    Assert-PublishTarget
    if ($Arguments -contains '--subscription' -or $Arguments -contains '--tenant') { throw 'CLI target selectors are owned by the publisher guard.' }
    $Arguments += @('--subscription', $script:PublishTarget.SubscriptionId)
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

function Get-AzCliText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Assert-PublishTarget
    if ($Arguments -contains '--subscription' -or $Arguments -contains '--tenant') { throw 'CLI target selectors are owned by the publisher guard.' }
    $Arguments += @('--subscription', $script:PublishTarget.SubscriptionId)
    $commandOutput = @(az @Arguments 2>&1)
    $commandText = Get-TextFromProcessOutput -Output $commandOutput
    if ($LASTEXITCODE -ne 0) {
        throw $commandText
    }

    return $commandText
}

function Test-AzRestNotFound {
    [CmdletBinding()]
    param(
        [string]$Text
    )

    return ($Text -match '(?i)\b(404|not\s+found|ResourceNotFound|No HTTP resource was found)\b')
}

function Get-AzAccessToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    Assert-PublishTarget
    $uri = [uri]$Url
    Assert-PublishRequestUri -Uri $uri
    $resource = switch ($uri.Host) {
        'management.azure.com' { 'https://management.azure.com/' }
        'graph.microsoft.com' { 'https://graph.microsoft.com' }
        default { 'https://storage.azure.com/' }
    }
    $key = "$resource|$($script:PublishTarget.SubscriptionId)|$($script:PublishTarget.TenantId)".ToLowerInvariant()
    if (-not (Get-Variable AzAccessTokenCache -Scope Script -ErrorAction SilentlyContinue)) { $script:AzAccessTokenCache = @{} }
    if ($script:AzAccessTokenCache.ContainsKey($key) -and $script:AzAccessTokenCache[$key].ExpiresOn -gt (Get-Date).AddMinutes(5)) {
        return $script:AzAccessTokenCache[$key].AccessToken
    }
    $response = Get-PublishTokenResponse -Resource $resource -Graph:($uri.Host -eq 'graph.microsoft.com')
    $expiresOn = Get-Date
    if ($response.PSObject.Properties['expiresOn']) {
        try { $expiresOn = [datetimeoffset]::Parse([string]$response.expiresOn).UtcDateTime } catch { throw 'Invalid token expiry metadata.' }
    }
    $script:AzAccessTokenCache[$key] = [pscustomobject]@{ AccessToken = $response.accessToken; ExpiresOn = $expiresOn }
    return $response.accessToken
}

function Invoke-AzRestJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [AllowNull()]
        [string]$Body,
        [switch]$AllowNotFound
    )

    $headers = @{
        Authorization = 'Bearer {0}' -f (Get-AzAccessToken -Url $Url)
        Accept = 'application/json'
    }

    $requestArguments = @{
        Method = $Method
        Uri = $Url
        Headers = $headers
        UseBasicParsing = $true
        SkipHttpErrorCheck = $true
        MaximumRedirection = 0
        TimeoutSec = 120
    }

    if ($PSBoundParameters.ContainsKey('Body') -and $Method -notin @('GET', 'DELETE')) {
        $requestArguments.Body = $Body
        $requestArguments.ContentType = 'application/json'
    }

    Assert-PublishTarget
    $response = Invoke-WebRequest @requestArguments
    $statusCode = [int]$response.StatusCode
    $responseText = [string]$response.Content

    if ($statusCode -eq 404 -and $AllowNotFound) {
        return $null
    }

    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        if ($AllowNotFound -and (Test-AzRestNotFound -Text $responseText)) {
            return $null
        }

        $errorText = if ([string]::IsNullOrWhiteSpace($responseText)) {
            'Request failed with no response body.'
        }
        else {
            $responseText
        }

        throw "HTTP $statusCode from '$Url': $errorText"
    }

    if ([string]::IsNullOrWhiteSpace($responseText)) {
        return $null
    }

    try {
        return $responseText | ConvertFrom-Json
    }
    catch {
        return $responseText
    }
}

function Resolve-BooleanString {
    [CmdletBinding()]
    param(
        [AllowNull()]
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
        default {
            throw "Unable to interpret boolean value '$Value'."
        }
    }
}

function Assert-ObjectFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string[]]$FieldNames,
        [string]$Description = 'Object'
    )

    foreach ($fieldName in $FieldNames) {
        if ($InputObject.PSObject.Properties.Match($fieldName).Count -eq 0) {
            throw "$Description is missing required field '$fieldName'."
        }

        $value = $InputObject.$fieldName
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            throw "$Description field '$fieldName' is empty."
        }
    }
}

function Get-UpstreamCompatibilityLock {
    [CmdletBinding()]
    param(
        [string]$LockPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'contracts\upstream-lock.json')
    )

    $resolvedLockPath = Resolve-AbsolutePath -Path $LockPath
    if (-not (Test-Path -LiteralPath $resolvedLockPath -PathType Leaf)) {
        throw "Upstream compatibility lock was not found: $resolvedLockPath"
    }

    $lock = Get-Content -LiteralPath $resolvedLockPath -Raw | ConvertFrom-Json -Depth 20
    Assert-ObjectFields -InputObject $lock -FieldNames @('schemaVersion', 'repository', 'ref', 'commit', 'contracts') -Description 'Upstream compatibility lock'
    if ([int]$lock.schemaVersion -ne 1) {
        throw "Unsupported upstream compatibility lock schemaVersion '$($lock.schemaVersion)'."
    }

    return $lock
}

function Get-HostedAssetsContract {
    [CmdletBinding()]
    param(
        [string]$ContractPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'contracts\hosted-assets.json')
    )

    $resolvedContractPath = Resolve-AbsolutePath -Path $ContractPath
    if (-not (Test-Path -LiteralPath $resolvedContractPath -PathType Leaf)) {
        throw "Hosted assets contract was not found: $resolvedContractPath"
    }

    $contract = Get-Content -LiteralPath $resolvedContractPath -Raw | ConvertFrom-Json -Depth 20
    Assert-ObjectFields -InputObject $contract -FieldNames @('schemaVersion', 'dashboardBlobNames', 'hostedAssetsDirectory', 'assets') -Description 'Hosted assets contract'
    if ([int]$contract.schemaVersion -ne 1) {
        throw "Unsupported hosted assets contract schemaVersion '$($contract.schemaVersion)'."
    }

    $paths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($asset in @($contract.assets)) {
        Assert-ObjectFields -InputObject $asset -FieldNames @('path', 'required') -Description 'Hosted asset entry'
        $assetPath = [string]$asset.path
        if ($assetPath -match '(^[\\/])|(^|[\\/])\.\.([\\/]|$)|\\') {
            throw "Hosted asset path '$assetPath' is not a safe forward-slash relative path."
        }
        if (-not $paths.Add($assetPath)) {
            throw "Hosted asset path '$assetPath' is duplicated."
        }
    }

    return $contract
}

function Get-AzdEnvironmentValues {
    [CmdletBinding()]
    param()

    $cachedValues = Get-Variable -Name AzdEnvironmentValues -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $cachedValues) {
        return $script:AzdEnvironmentValues
    }

    $script:AzdEnvironmentValues = @{}
    $azdCommand = Get-Command -Name 'azd' -ErrorAction SilentlyContinue
    if ($null -eq $azdCommand) {
        return $script:AzdEnvironmentValues
    }

    $commandOutput = @(& $azdCommand.Source env get-values 2>&1)
    $commandText = Get-TextFromProcessOutput -Output $commandOutput
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commandText)) {
        return $script:AzdEnvironmentValues
    }

    foreach ($line in ($commandText -split "`r?`n")) {
        if ($line -notmatch '^(?:export\s+)?([A-Za-z0-9_]+)=(.*)$') {
            continue
        }

        $name = $Matches[1]
        $rawValue = $Matches[2].Trim()
        if ($rawValue.Length -ge 2) {
            $quote = $rawValue[0]
            if (($quote -eq '"' -or $quote -eq "'") -and $rawValue[-1] -eq $quote) {
                $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
            }
        }

        $script:AzdEnvironmentValues[$name] = $rawValue
    }

    return $script:AzdEnvironmentValues
}

function Get-EnvironmentValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($processValue)) {
        return $processValue
    }

    $azdValues = Get-AzdEnvironmentValues
    if ($azdValues.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$azdValues[$Name])) {
        return [string]$azdValues[$Name]
    }

    return $null
}

function Resolve-ResourceGroupNameFromResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceType
    )

    $resourceGroups = @(
        Get-AzCliJson -Arguments @(
            'resource', 'list',
            '--name', $ResourceName,
            '--resource-type', $ResourceType,
            '--query', '[].resourceGroup',
            '--output', 'json'
        )
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $resourceGroups = @($resourceGroups)

    if ($resourceGroups.Count -eq 0) {
        throw "Resource '$ResourceName' of type '$ResourceType' was not found."
    }

    $uniqueGroups = @($resourceGroups | Sort-Object -Unique)
    if ($uniqueGroups.Count -gt 1) {
        throw "Resource '$ResourceName' of type '$ResourceType' exists in multiple resource groups: $($uniqueGroups -join ', '). Pass -ResourceGroupName explicitly."
    }

    return [string]$uniqueGroups[0]
}

function Resolve-SingleResourceNameInGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$ResourceType,
        [Parameter(Mandatory = $true)]
        [string]$FriendlyName
    )

    $resourceNames = @(
        Get-AzCliJson -Arguments @(
            'resource', 'list',
            '--resource-group', $ResourceGroupName,
            '--resource-type', $ResourceType,
            '--query', '[].name',
            '--output', 'json'
        )
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $resourceNames = @($resourceNames)

    if ($resourceNames.Count -eq 0) {
        throw "No $FriendlyName resources were found in resource group '$ResourceGroupName'."
    }

    if ($resourceNames.Count -gt 1) {
        throw "Multiple $FriendlyName resources were found in resource group '$ResourceGroupName': $($resourceNames -join ', '). Pass the name explicitly."
    }

    return [string]$resourceNames[0]
}

function Assert-ManualAutomationMode {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Mode)

    if ($Mode.ComputeKind -ne 'automation' -or $Mode.WebKind -ne 'none' -or $Mode.EffectivePackageMode -ne 'selfcontained') {
        throw '-ManualOnly requires COMPUTE_KIND=automation, WEB_KIND=none and selfcontained package mode.'
    }
}

function Assert-AutomationSchedulesAbsent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [Parameter(Mandatory = $true)][string]$AutomationAccountName
    )

    $account = Get-AzCliJson -Arguments @(
        'resource', 'show', '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.Automation/automationAccounts',
        '--name', $AutomationAccountName, '--output', 'json'
    )
    Assert-PublishResourceId -Resource $account -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Automation/automationAccounts' -Name $AutomationAccountName

    foreach ($collection in @('schedules', 'jobSchedules')) {
        $url = "https://management.azure.com$($account.id)/${collection}?api-version=2023-11-01"
        $headers = @{
            Authorization = 'Bearer {0}' -f (Get-AzAccessToken -Url $url)
            Accept = 'application/json'
        }
        Assert-PublishTarget
        $httpResponse = Invoke-WebRequest -Method GET -Uri $url -Headers $headers `
            -UseBasicParsing:$true -SkipHttpErrorCheck:$true -MaximumRedirection 0 -TimeoutSec 120
        if ([int]$httpResponse.StatusCode -ne 200) {
            throw "-ManualOnly could not read the complete '$collection' inventory (HTTP $($httpResponse.StatusCode))."
        }
        # Preserve and validate the root shape here, before PowerShell can
        # enumerate a singleton array through a helper's return pipeline.
        try {
            $response = ConvertFrom-Json -InputObject ([string]$httpResponse.Content) -NoEnumerate -ErrorAction Stop
        }
        catch {
            throw "-ManualOnly could not parse the '$collection' inventory as JSON."
        }
        # A partial, missing or malformed listing cannot establish an isolated,
        # schedule-free account. Do not disable or delete another operator's work.
        if ($response -isnot [pscustomobject] -or -not $response.PSObject.Properties['value'] -or
            $response.value -isnot [array] -or $response.value.Count -ne 0) {
            throw "-ManualOnly requires an Automation account with no schedules or job-schedule links; '$collection' was not confirmed empty."
        }
        $nextLink = $response.PSObject.Properties['nextLink']
        if ($nextLink -and $null -ne $nextLink.Value -and
            ($nextLink.Value -isnot [string] -or $nextLink.Value -ne '')) {
            throw "-ManualOnly requires a complete '$collection' inventory with no continuation link."
        }
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

    return Resolve-SingleResourceNameInGroup `
        -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Storage/storageAccounts' `
        -FriendlyName 'storage account'
}

. (Join-Path $PSScriptRoot 'Publish-TargetGuard.ps1')
