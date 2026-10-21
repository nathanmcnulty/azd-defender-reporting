#Requires -Version 7.6
# Trusted worker protocol. No credentials are accepted through stdin or returned.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$WarningPreference='SilentlyContinue'
$ProgressPreference='SilentlyContinue'
try {
    Import-Module (Join-Path $PSScriptRoot 'AutomationValidationAdapter.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'AutomationValidationPreflight.psm1') -Force
    . (Join-Path $PSScriptRoot 'Common-AzurePublish.ps1')
    $text=[Console]::In.ReadToEnd()
    if($text.Length -gt 131072){throw 'Input bound exceeded.'}
    [AzdValidation.BoundedIO]::ValidateJsonObject($text)
    $message=$text | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 32
    $context=$message.context
    Assert-ValidationContext $context | Out-Null
    if(($message.budget -isnot [int] -and $message.budget -isnot [long]) -or $message.budget -lt 1 -or $message.budget -gt 30 -or $message.action -cnotin @('Guard','Preflight','Request')){throw 'Invalid action.'}
    $message.budget=[int]$message.budget
    if($message.action -ceq 'Request'){Assert-ValidationJobRequest -Context $context -Method $message.method -Uri $message.uri -Body $message.body | Out-Null}
    Initialize-PublishTarget -SubscriptionId $context.SubscriptionId -TenantId $context.TenantId
    $operator=Get-AzCliJson -Arguments @('account','show','--output','json')
    if($operator.user.type -cne 'user' -or $operator.user.name -isnot [string] -or $operator.user.name -ine $context.ExpectedUserName){throw 'Operator identity mismatch.'}
    if($message.action -ceq 'Guard') {$result=$true}
    else {
        $armToken=(Get-PublishTokenResponse -Resource 'https://management.azure.com/').accessToken
        $storageToken=$null
        if($message.action -ceq 'Preflight') {$storageToken=(Get-PublishTokenResponse -Resource 'https://storage.azure.com/').accessToken}
        $groupId="/subscriptions/$($context.SubscriptionId)/resourceGroups/$($context.ResourceGroupName)"
        $jobId="$groupId/providers/Microsoft.Automation/automationAccounts/$($context.AutomationAccountName)/jobs/$($context.JobId)"
        $jobUri="https://management.azure.com${jobId}?api-version=2024-10-23"
        $stopUri="https://management.azure.com${jobId}/stop?api-version=2024-10-23"
        if($message.action -ceq 'Request') {
            if(-not (($message.method -cin @('GET','PUT') -and $message.uri -ceq $jobUri) -or ($message.method -ceq 'POST' -and $message.uri -ceq $stopUri))){throw 'Request outside exact job allowlist.'}
            $bodyText=$null
            if($message.method -ceq 'PUT') {
                $expected=[ordered]@{properties=[ordered]@{runbook=[ordered]@{name=$context.RunbookName};parameters=[ordered]@{StorageAccountName=$context.StorageAccountName;UseExistingExportsOnly='true';IncludeAdvancedHunting='false';UseDirectMergeDeviceLookup='false';DashboardDeliveryMode='SelfContained';Export='BlobStorage'}}}
                # Context and the lifecycle's ordered payload use the same fixed shape.
                $bodyText=$expected | ConvertTo-Json -Depth 10 -Compress
            } elseif($null -ne $message.body){throw 'Unexpected request body.'}
            # Fresh maintained target check immediately before HTTP mutations.
            if($message.method -cne 'GET'){Assert-PublishTarget}
            $http=[AzdValidation.BoundedIO]::Send($message.method,[uri]$message.uri,$armToken,$bodyText,$message.budget).GetAwaiter().GetResult()
            $body=$null
            if($http.StatusCode -ge 200 -and $http.StatusCode -lt 300 -and $http.Bytes.Length -gt 0) {
                $bodyJson=[Text.UTF8Encoding]::new($false,$true).GetString($http.Bytes)
                [AzdValidation.BoundedIO]::ValidateJsonObject($bodyJson)
                $body=$bodyJson | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 32
            }
            $result=@{StatusCode=[int]$http.StatusCode;Body=$body}
        } else {
            $read={
                param($uri,$audience,$method)
                if($method -cnotin @('GET','HEAD')){throw 'Preflight is read-only.'}
                $parsed=[uri]$uri
                $token=if($audience -ceq 'ARM' -and $parsed.Host -ceq 'management.azure.com' -and $parsed.AbsolutePath.StartsWith($groupId+'/',[StringComparison]::OrdinalIgnoreCase)){$armToken}
                    elseif($audience -ceq 'Storage' -and $parsed.Host -ceq "$($context.StorageAccountName).blob.core.windows.net"){$storageToken}
                    else{throw 'Preflight token destination mismatch.'}
                $http=[AzdValidation.BoundedIO]::Send($method,$parsed,$token,$null,$message.budget).GetAwaiter().GetResult()
                if($audience -ceq 'ARM' -and $http.StatusCode -eq 200 -and $parsed.AbsolutePath -notlike '*/content'){
                    [AzdValidation.BoundedIO]::ValidateJsonObject([Text.UTF8Encoding]::new($false,$true).GetString($http.Bytes))
                }
                return @{StatusCode=[int]$http.StatusCode;Bytes=$http.Bytes}
            }
            $result=Assert-AutomationValidationPreflight -Context $context -Read $read
        }
    }
    [Console]::Out.Write((@{ok=$true;result=$result} | ConvertTo-Json -Depth 32 -Compress))
} catch {
    # Never emit raw CLI/HTTP exceptions, URIs, headers, tokens or provider bodies.
    [Console]::Out.Write('{"ok":false,"result":null}')
}
