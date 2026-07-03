#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$AutomationAccountName,
    [string]$StorageAccountName,
    [string]$RepositoryPath = $env:DEFENDER_REPORTING_PATH,
    [string]$RepositoryUrl = $env:DEFENDER_REPORTING_REPO,
    [string]$Ref = $env:DEFENDER_REPORTING_REF,
    [switch]$BuildOnly,
    [switch]$SkipTemplatePublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeEnvironmentApiVersion = '2024-10-23'
$automationAccountApiVersion = '2023-11-01'
$runtimeEnvironmentName = 'PowerShell-74-AzAccounts'
$runbookName = 'Invoke-DashboardPipeline'
$dailyScheduleName = 'DashboardPipeline-Daily'
$legacyWeeklyScheduleName = 'DashboardPipeline-Every7Days'

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

function Get-AzCliText {
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

    return $commandText
}

function Get-ErrorMessageText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    return ($ErrorRecord | Out-String).Trim()
}

function Test-IsArmNotFoundError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $text = Get-ErrorMessageText -ErrorRecord $ErrorRecord
    return ($text -match '(?i)\b(HTTP\s*404|StatusCode\s*:?\s*404|ResourceGroupNotFound|ResourceNotFound|NotFound|could not be found|was not found)\b')
}

function Get-ArmAccessToken {
    [CmdletBinding()]
    param()

    $tokenText = Get-AzCliText -Arguments @(
        'account', 'get-access-token',
        '--resource', 'https://management.azure.com/',
        '--query', 'accessToken',
        '--output', 'tsv'
    )

    if ([string]::IsNullOrWhiteSpace($tokenText)) {
        throw 'Unable to acquire an Azure Resource Manager access token.'
    }

    return $tokenText.Trim()
}

function Invoke-ArmApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE')]
        [string]$Method,
        [string]$Payload,
        [string]$ContentType = 'application/json'
    )

    $requestUri = if ($Path.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Path
    }
    else {
        "https://management.azure.com$Path"
    }

    $headers = @{
        Authorization = "Bearer $(Get-ArmAccessToken)"
    }

    if ($Method -eq 'GET' -or $Method -eq 'DELETE') {
        return Invoke-RestMethod -Uri $requestUri -Method $Method -Headers $headers
    }

    if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
        $headers['Content-Type'] = $ContentType
    }

    if ($PSBoundParameters.ContainsKey('Payload')) {
        return Invoke-RestMethod -Uri $requestUri -Method $Method -Headers $headers -Body $Payload
    }

    return Invoke-RestMethod -Uri $requestUri -Method $Method -Headers $headers
}

function Get-OptionalArmResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return Invoke-ArmApi -Path $Path -Method GET
    }
    catch {
        if (Test-IsArmNotFoundError -ErrorRecord $_) {
            return $null
        }

        throw
    }
}

function Wait-WithPolling {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) {
            return
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw "Timed out while waiting for $Description."
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

function Get-DashboardDeliveryMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$EffectivePackageMode
    )

    switch ($EffectivePackageMode) {
        'hosted' { return 'Hosted' }
        'dual' { return 'Dual' }
        default { return 'SelfContained' }
    }
}

function Remove-AutomationJobSchedulesByScheduleName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionPath,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$AutomationAccountName,
        [Parameter(Mandatory = $true)]
        [string]$ScheduleName
    )

    $jobSchedulesPath = "$SubscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobSchedules?api-version=$automationAccountApiVersion"
    $jobSchedulesResponse = Invoke-ArmApi -Path $jobSchedulesPath -Method GET
    $jobSchedules = if ($null -eq $jobSchedulesResponse) {
        @()
    }
    elseif ($jobSchedulesResponse.PSObject.Properties['value']) {
        @($jobSchedulesResponse.value)
    }
    else {
        @($jobSchedulesResponse)
    }

    foreach ($jobSchedule in $jobSchedules) {
        if ($null -eq $jobSchedule) {
            continue
        }

        $jobScheduleName = ''
        if ($jobSchedule.PSObject.Properties['name']) {
            $jobScheduleName = [string]$jobSchedule.PSObject.Properties['name'].Value
        }
        if ([string]::IsNullOrWhiteSpace($jobScheduleName)) {
            $jobScheduleName = [string]$jobSchedule.properties.jobScheduleId
        }
        if ([string]::IsNullOrWhiteSpace($jobScheduleName) -and -not [string]::IsNullOrWhiteSpace([string]$jobSchedule.id)) {
            $jobScheduleName = Split-Path -Path ([string]$jobSchedule.id) -Leaf
        }

        $linkedScheduleName = ''
        if ($null -ne $jobSchedule.properties -and $null -ne $jobSchedule.properties.schedule) {
            $linkedScheduleName = [string]$jobSchedule.properties.schedule.name
        }

        if ([string]::IsNullOrWhiteSpace($jobScheduleName) -or $linkedScheduleName -ne $ScheduleName) {
            continue
        }

        $deletePath = "$SubscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobSchedules/${jobScheduleName}?api-version=$automationAccountApiVersion"
        Invoke-ArmApi -Path $deletePath -Method DELETE | Out-Null
    }
}

$mode = & (Join-Path $PSScriptRoot 'Get-DeploymentMode.ps1')
$dashboardDeliveryMode = Get-DashboardDeliveryMode -EffectivePackageMode $mode.EffectivePackageMode

$upstreamRepo = & (Join-Path $PSScriptRoot 'Resolve-UpstreamRepo.ps1') `
    -RepositoryUrl $RepositoryUrl `
    -Ref $Ref `
    -RepositoryPath $RepositoryPath

$buildScriptPath = Join-Path $upstreamRepo.ResolvedPath 'build\azure\Build-Runbook.ps1'
$runbookScriptPath = Join-Path $upstreamRepo.ResolvedPath 'azure\Invoke-DashboardPipeline.ps1'

if (-not (Test-Path -LiteralPath $buildScriptPath -PathType Leaf)) {
    throw "Required upstream runbook build script was not found: $buildScriptPath"
}

Write-Output ("Resolved upstream repo: {0} ({1})" -f $upstreamRepo.ResolvedPath, $upstreamRepo.Commit)
Write-Output ("Building Azure Automation runbook with upstream script: {0}" -f $buildScriptPath)

& $buildScriptPath

if (-not (Test-Path -LiteralPath $runbookScriptPath -PathType Leaf)) {
    throw "Expected generated runbook artifact was not found: $runbookScriptPath"
}

$result = [PSCustomObject]@{
    UpstreamRepositoryPath = $upstreamRepo.ResolvedPath
    UpstreamCommit = $upstreamRepo.Commit
    RunbookScriptPath = $runbookScriptPath
    RunbookName = $runbookName
    RuntimeEnvironmentName = $runtimeEnvironmentName
    DashboardDeliveryMode = $dashboardDeliveryMode
}

if ($BuildOnly) {
    $result
    return
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($AutomationAccountName)) {
    throw 'ResourceGroupName and AutomationAccountName are required unless -BuildOnly is specified.'
}

if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required for Automation runbook publish.'
}

$automationAccount = Get-AzCliJson -Arguments @(
    'resource', 'show',
    '--resource-group', $ResourceGroupName,
    '--resource-type', 'Microsoft.Automation/automationAccounts',
    '--name', $AutomationAccountName,
    '--query', '{id:id,location:location}',
    '--output', 'json'
)

if ($null -eq $automationAccount -or [string]::IsNullOrWhiteSpace([string]$automationAccount.location)) {
    throw "Automation Account '$AutomationAccountName' was not found in resource group '$ResourceGroupName'."
}

$resolvedStorageAccountName = Resolve-StorageAccountName -ResourceGroupName $ResourceGroupName -RequestedStorageAccountName $StorageAccountName

if (-not $SkipTemplatePublish) {
    & (Join-Path $PSScriptRoot 'Publish-TemplateAssets.ps1') `
        -StorageAccountName $resolvedStorageAccountName `
        -RepositoryPath $upstreamRepo.ResolvedPath | Out-Null
}

$subscriptionId = (Get-AzCliText -Arguments @('account', 'show', '--query', 'id', '--output', 'tsv')).Trim()
if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
    throw 'Unable to determine the current Azure subscription ID.'
}

$subscriptionPath = "/subscriptions/$subscriptionId"
$automationLocation = [string]$automationAccount.location

$runtimeEnvironmentPath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runtimeEnvironments/${runtimeEnvironmentName}?api-version=$runtimeEnvironmentApiVersion"
$runtimeEnvironmentPayload = @{
    location = $automationLocation
    properties = @{
        runtime = @{
            language = 'PowerShell'
            version = '7.4'
        }
        defaultPackages = @{}
        description = 'PowerShell 7.4 with Az.Accounts only (no full Az module or Az CLI)'
    }
} | ConvertTo-Json -Depth 6

Invoke-ArmApi -Path $runtimeEnvironmentPath -Method PUT -Payload $runtimeEnvironmentPayload | Out-Null

$packagePath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runtimeEnvironments/$runtimeEnvironmentName/packages/Az.Accounts?api-version=$runtimeEnvironmentApiVersion"
$packagePayload = @{
    location = $automationLocation
    properties = @{
        contentLink = @{
            uri = 'https://www.powershellgallery.com/api/v2/package/Az.Accounts'
        }
    }
} | ConvertTo-Json -Depth 5

Invoke-ArmApi -Path $packagePath -Method PUT -Payload $packagePayload | Out-Null

Wait-WithPolling -Description 'Az.Accounts package import' -IntervalSeconds 10 -TimeoutSeconds 300 -Condition {
    $packageState = Get-OptionalArmResource -Path $packagePath
    if ($null -eq $packageState -or $null -eq $packageState.properties) {
        return $false
    }

    $provisioningState = [string]$packageState.properties.provisioningState
    return ($provisioningState -eq 'Succeeded' -or $provisioningState -eq 'Created')
}

$runbookPath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/${runbookName}?api-version=$runtimeEnvironmentApiVersion"
$runbookPayload = @{
    location = $automationLocation
    properties = @{
        runbookType = 'PowerShell'
        runtimeEnvironment = $runtimeEnvironmentName
        logProgress = $true
        logVerbose = $false
        description = 'Exports MDE vulnerability data, generates the HTML dashboard, and uploads results to blob storage.'
    }
} | ConvertTo-Json -Depth 6

Invoke-ArmApi -Path $runbookPath -Method PUT -Payload $runbookPayload | Out-Null

$runbookContent = Get-Content -LiteralPath $runbookScriptPath -Raw
$draftContentUri = "https://management.azure.com$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/$runbookName/draft/content?api-version=$runtimeEnvironmentApiVersion"
Invoke-ArmApi -Path $draftContentUri -Method PUT -Payload $runbookContent -ContentType 'text/powershell' | Out-Null

$publishPath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/runbooks/$runbookName/publish?api-version=$runtimeEnvironmentApiVersion"
Invoke-ArmApi -Path $publishPath -Method POST -Payload '{}' | Out-Null

$automationVariables = @(
    [PSCustomObject]@{
        Name = 'StorageAccountName'
        Value = $resolvedStorageAccountName
        Description = 'Storage account name for the dashboard pipeline'
    }
    [PSCustomObject]@{
        Name = 'DashboardDeliveryMode'
        Value = $dashboardDeliveryMode
        Description = 'Dashboard packaging mode for the pipeline (SelfContained, Hosted, or Dual)'
    }
)

foreach ($automationVariable in $automationVariables) {
    $variablePath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/variables/$($automationVariable.Name)?api-version=$automationAccountApiVersion"
    $variablePayload = @{
        properties = @{
            value = "`"$($automationVariable.Value)`""
            isEncrypted = $false
            description = $automationVariable.Description
        }
    } | ConvertTo-Json -Depth 5

    Invoke-ArmApi -Path $variablePath -Method PUT -Payload $variablePayload | Out-Null
}

$schedulePath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/schedules/${dailyScheduleName}?api-version=$automationAccountApiVersion"
$legacySchedulePath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/schedules/${legacyWeeklyScheduleName}?api-version=$automationAccountApiVersion"
$startTime = [DateTime]::UtcNow.Date.AddDays(1).AddHours(2).ToString('yyyy-MM-ddTHH:mm:ssZ')

$schedulePayload = @{
    properties = @{
        description = 'Runs the dashboard pipeline daily'
        startTime = $startTime
        frequency = 'Day'
        interval = 1
        isEnabled = $true
        timeZone = 'UTC'
    }
} | ConvertTo-Json -Depth 5

Remove-AutomationJobSchedulesByScheduleName -SubscriptionPath $subscriptionPath -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ScheduleName $dailyScheduleName
Remove-AutomationJobSchedulesByScheduleName -SubscriptionPath $subscriptionPath -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ScheduleName $legacyWeeklyScheduleName

try {
    Invoke-ArmApi -Path $legacySchedulePath -Method DELETE | Out-Null
}
catch {
    if (-not (Test-IsArmNotFoundError -ErrorRecord $_)) {
        throw
    }
}

Invoke-ArmApi -Path $schedulePath -Method PUT -Payload $schedulePayload | Out-Null

$jobScheduleId = [Guid]::NewGuid().ToString()
$jobSchedulePath = "$subscriptionPath/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobSchedules/${jobScheduleId}?api-version=$automationAccountApiVersion"
$jobSchedulePayload = @{
    properties = @{
        runbook = @{ name = $runbookName }
        schedule = @{ name = $dailyScheduleName }
        parameters = @{
            StorageAccountName = $resolvedStorageAccountName
            DashboardDeliveryMode = $dashboardDeliveryMode
        }
    }
} | ConvertTo-Json -Depth 6

Invoke-ArmApi -Path $jobSchedulePath -Method PUT -Payload $jobSchedulePayload | Out-Null

$result | Add-Member -NotePropertyName StorageAccountName -NotePropertyValue $resolvedStorageAccountName
$result | Add-Member -NotePropertyName ScheduleName -NotePropertyValue $dailyScheduleName

$result
