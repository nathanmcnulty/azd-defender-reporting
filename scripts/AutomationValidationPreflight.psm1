#Requires -Version 7.6
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'AutomationRuntimeContract.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'AutomationJobParameters.psm1') -ErrorAction Stop

function Assert-ValidationContext {
    <#.SYNOPSIS
    Validates the exact approved synthetic cell binding without provider access.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context)
    $allowedKeys=@('TenantId','SubscriptionId','JobId','AutomationPrincipalId','ResourceGroupName','AutomationAccountName','RunbookName','StorageAccountName','RunbookSha256','FixtureSha256','RuntimeContractSha256','ExpectedUserName','Artifacts','Templates')
    if($Context.Contains('ParameterEncoding')){
        if($Context.ParameterEncoding -isnot [string] -or $Context.ParameterEncoding -cne 'JsonValues'){throw 'Invalid parameter encoding.'}
        $allowedKeys+='ParameterEncoding'
    }
    if($Context.Count -ne $allowedKeys.Count -or @($Context.Keys | Where-Object {$_ -cnotin $allowedKeys}).Count){throw 'Unexpected context fields.'}
    foreach ($key in @('TenantId','SubscriptionId','JobId','AutomationPrincipalId')) {
        $parsed=[guid]::Empty
        if ($Context[$key] -isnot [string] -or -not [guid]::TryParseExact($Context[$key], 'D', [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Invalid context GUID.' }
    }
    $patterns=@{ResourceGroupName='\A[A-Za-z0-9_().-]{1,90}\z';AutomationAccountName='\A[A-Za-z0-9][A-Za-z0-9-]{0,62}\z';RunbookName='\A[A-Za-z][A-Za-z0-9_-]{0,62}\z';StorageAccountName='\A[a-z0-9]{3,24}\z';RunbookSha256='\A[a-f0-9]{64}\z';FixtureSha256='\A[a-f0-9]{64}\z';ExpectedUserName='\A[^\s]{1,200}\z'}
    foreach ($key in $patterns.Keys) { if ($Context[$key] -isnot [string] -or $Context[$key] -cnotmatch $patterns[$key]) { throw 'Invalid context field.' } }
    if ($Context.ResourceGroupName.EndsWith('.')) { throw 'Invalid resource group.' }
    $runtimeContract=AutomationRuntimeContract\Get-AutomationRuntimeContract
    if($Context.RuntimeContractSha256 -isnot [string] -or $Context.RuntimeContractSha256 -cne $runtimeContract.Sha256){throw 'Runtime contract binding mismatch.'}
    foreach ($kind in @('Artifacts','Templates')) {
        if ($Context[$kind] -isnot [array] -or $Context[$kind].Count -lt 1 -or $Context[$kind].Count -gt 100) { throw 'Invalid expected artifact set.' }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $identities=[Collections.Generic.List[string]]::new()
        $totalBytes=0L
        foreach ($entry in $Context[$kind]) {
            $pattern=if($kind -eq 'Artifacts'){'\A(?:Machines_Current\.json\.gz|VulnExport_[0-9]+_[0-9]{4}-[0-9]{2}-[0-9]{2}\.json\.gz)\z'}else{'\A[A-Za-z0-9][A-Za-z0-9_.-]{0,100}(?:/[A-Za-z0-9][A-Za-z0-9_.-]{0,100}){0,5}\z'}
            if ($entry -isnot [Collections.IDictionary] -or $entry.name -isnot [string] -or $entry.name -cnotmatch $pattern -or -not $seen.Add($entry.name) -or
                $entry.sha256 -isnot [string] -or $entry.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or
                ($entry.bytes -isnot [long] -and $entry.bytes -isnot [int]) -or $entry.bytes -le 0 -or $entry.bytes -gt 1MB) { throw 'Invalid expected artifact identity.' }
            $identities.Add(('{0}|{1}|{2}' -f $entry.name,$entry.bytes,$entry.sha256))
            $totalBytes += $entry.bytes
            if($totalBytes -gt 10MB){throw 'Expected artifact set exceeds its size bound.'}
        }
        if ($kind -eq 'Artifacts') {
            if (-not $seen.Contains('Machines_Current.json.gz') -or $seen.Count -lt 2) { throw 'Missing required synthetic inputs.' }
            $identities.Sort([StringComparer]::Ordinal)
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($identities -join "`n")))).ToLowerInvariant()
            if ($hash -cne $Context.FixtureSha256) { throw 'Expected artifact set does not match the approved fixture identity.' }
        }
    }
    return $true
}

function Assert-AutomationValidationPreflight {
    <#.SYNOPSIS
    Reads and verifies the exact isolated account, published code and blob inputs.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context,
        # Read(uri, audience, method) -> {StatusCode:int;Bytes:byte[]}; GET/HEAD only.
        [Parameter(Mandatory)][scriptblock]$Read
    )
    $ErrorActionPreference='Stop'
    Assert-ValidationContext $Context | Out-Null
    $groupId="/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ResourceGroupName)"
    $accountId="$groupId/providers/Microsoft.Automation/automationAccounts/$($Context.AutomationAccountName)"
    $storageId="$groupId/providers/Microsoft.Storage/storageAccounts/$($Context.StorageAccountName)"
    function Read-Object([string]$Path) {
        $response=& $Read "https://management.azure.com$Path" 'ARM' 'GET'
        if($response.StatusCode -isnot [int] -or $response.StatusCode -ne 200 -or $response.Bytes -isnot [byte[]] -or $response.Bytes.Length -gt 1MB){throw 'Required ARM read failed.'}
        # Strict duplicate-property validation is owned by the transport parser.
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($response.Bytes)
        $value=$text | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 32
        if($value -isnot [Collections.IDictionary]){throw 'ARM response must be an object.'}
        return $value
    }
    $account=Read-Object "${accountId}?api-version=2023-11-01"
    if($account.id -isnot [string] -or $account.id -ine $accountId -or $account.identity.principalId -isnot [string] -or $account.identity.principalId -ine $Context.AutomationPrincipalId){throw 'Automation account identity mismatch.'}
    $storage=Read-Object "${storageId}?api-version=2023-05-01"
    $blobBase="https://$($Context.StorageAccountName).blob.core.windows.net"
    if($storage.id -isnot [string] -or $storage.id -ine $storageId -or $storage.properties.primaryEndpoints.blob -cne "$blobBase/"){throw 'Storage binding mismatch.'}
    foreach($collection in @('schedules','jobSchedules','jobs')) {
        $listing=Read-Object "$accountId/${collection}?api-version=2024-10-23"
        if($listing.value -isnot [array] -or ($listing.Contains('nextLink') -and $null -ne $listing.nextLink -and
            ($listing.nextLink -isnot [string] -or $listing.nextLink -cne ''))){throw 'Incomplete Automation collection.'}
        if($collection -ne 'jobs' -and $listing.value.Count -ne 0){throw 'Account is not schedule-free.'}
        if($collection -eq 'jobs') {
            foreach($job in $listing.value){if($job.properties.status -cnotin @('Completed','Failed','Stopped')){throw 'Another unresolved or active job exists.'}}
        }
    }
    $runbookId="$accountId/runbooks/$($Context.RunbookName)"
    $runbook=Read-Object "${runbookId}?api-version=2024-10-23"
    $runtimeContract=AutomationRuntimeContract\Get-AutomationRuntimeContract
    $runtimeId="$accountId/runtimeEnvironments/$($runtimeContract.Spec.runtimeEnvironmentName)"
    if($runbook.id -isnot [string] -or $runbook.id -ine $runbookId -or $runbook.properties.state -cne 'Published' -or $runbook.properties.runbookType -cne 'PowerShell' -or
        $runbook.properties.runtimeEnvironment -isnot [string] -or $runbook.properties.runtimeEnvironment -cne $runtimeContract.Spec.runtimeEnvironmentName){throw 'Published runbook metadata mismatch.'}
    if($Context.Contains('ParameterEncoding')){
        $types=AutomationJobParameters\Get-ValidationParameterTypes
        $metadata=$runbook.properties.parameters
        if($metadata -isnot [Collections.IDictionary]){throw 'Published parameter metadata is missing.'}
        foreach($key in $types.Keys){
            $names=@($metadata.Keys|Where-Object {$_ -ieq $key})
            if($names.Count -ne 1){throw 'Published parameter name mismatch.'}
            $entry=$metadata[$names[0]]
            if($entry -isnot [Collections.IDictionary] -or
                $entry.type -isnot [string] -or $entry.type -cne $types[$key]){throw 'Published parameter type mismatch.'}
        }
        foreach($key in $metadata.Keys){
            $entry=$metadata[$key]
            if($entry -isnot [Collections.IDictionary] -or $entry.isMandatory -isnot [bool]){throw 'Invalid published parameter metadata.'}
            if($key -notin @($types.Keys) -and $entry.isMandatory){throw 'Unexpected required published parameter.'}
        }
    }
    AutomationRuntimeContract\Assert-AutomationRuntimeReadback -RuntimeId $runtimeId `
        -Runtime (Read-Object "${runtimeId}?api-version=2024-10-23") `
        -Packages (Read-Object "$runtimeId/packages?api-version=2024-10-23") | Out-Null
    $content=& $Read "https://management.azure.com$runbookId/content?api-version=2024-10-23" 'ARM' 'GET'
    if($content.StatusCode -ne 200 -or $content.Bytes -isnot [byte[]] -or $content.Bytes.Length -gt 1MB){throw 'Published runbook content read failed.'}
    $contentHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($content.Bytes)).ToLowerInvariant()
    if($contentHash -cne $Context.RunbookSha256){throw 'Published runbook bytes mismatch.'}
    $control=& $Read "$blobBase/dashboards/_diagnostics/ExportAndGenerate.control.json" 'Storage' 'HEAD'
    if($control.StatusCode -isnot [int] -or $control.StatusCode -ne 404){throw 'Control-blob absence is not confirmed.'}
    foreach($container in @('exports','templates')) {
        $expected=@(if($container -eq 'exports'){$Context.Artifacts}else{$Context.Templates})
        $response=& $Read "$blobBase/${container}?restype=container&comp=list&maxresults=101" 'Storage' 'GET'
        if($response.StatusCode -ne 200 -or $response.Bytes -isnot [byte[]] -or $response.Bytes.Length -gt 1MB){throw 'Blob list read failed.'}
        $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
        $stream=[IO.MemoryStream]::new($response.Bytes,$false)
        $reader=[Xml.XmlReader]::Create($stream,$settings)
        try{$xml=[Xml.XmlDocument]::new();$xml.XmlResolver=$null;$xml.Load($reader)}finally{$reader.Dispose();$stream.Dispose()}
        if($xml.DocumentElement.Name -cne 'EnumerationResults' -or $null -eq $xml.SelectSingleNode('/EnumerationResults/Blobs') -or
            $xml.SelectNodes('/EnumerationResults/NextMarker').Count -ne 1 -or $xml.SelectSingleNode('/EnumerationResults/NextMarker').InnerText -cne '' -or
            $xml.SelectNodes('/EnumerationResults/Blobs/BlobPrefix').Count -gt 0){throw 'Incomplete or unexpected blob enumeration.'}
        $observed=@($xml.SelectNodes('/EnumerationResults/Blobs/Blob'))
        if($observed.Count -ne $expected.Count){throw 'Unexpected blob count.'}
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($blob in $observed) {
            $nameNodes=$blob.SelectNodes('Name')
            if($nameNodes.Count -ne 1 -or -not $names.Add($nameNodes[0].InnerText)){throw 'Ambiguous blob identity.'}
        }
        foreach($entry in $expected) {
            if(-not $names.Contains($entry.name)){throw 'Remote artifact set mismatch.'}
            $blob=& $Read "$blobBase/$container/$($entry.name)" 'Storage' 'GET'
            if($blob.StatusCode -ne 200 -or $blob.Bytes -isnot [byte[]] -or $blob.Bytes.Length -ne $entry.bytes){throw 'Remote artifact size mismatch.'}
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($blob.Bytes)).ToLowerInvariant()
            if($hash -cne $entry.sha256){throw 'Remote artifact hash mismatch.'}
        }
    }
    return $true
}

function Assert-ValidationJobRequest {
    <#.SYNOPSIS
    Rejects any request outside the one approved job and fixed synthetic payload.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context,[string]$Method,[string]$Uri,$Body)
    Assert-ValidationContext $Context | Out-Null
    $id="/subscriptions/$($Context.SubscriptionId)/resourceGroups/$($Context.ResourceGroupName)/providers/Microsoft.Automation/automationAccounts/$($Context.AutomationAccountName)/jobs/$($Context.JobId)"
    $jobUri="https://management.azure.com${id}?api-version=2024-10-23"
    $stopUri="https://management.azure.com${id}/stop?api-version=2024-10-23"
    if(-not (($Method -cin @('GET','PUT') -and $Uri -ceq $jobUri) -or ($Method -ceq 'POST' -and $Uri -ceq $stopUri))){throw 'Request outside exact job allowlist.'}
    if($Method -cne 'PUT'){if($null -ne $Body){throw 'Unexpected request body.'};return $true}
    if($Body -isnot [Collections.IDictionary] -or $Body.Count -ne 1 -or $Body.properties -isnot [Collections.IDictionary] -or $Body.properties.Count -ne 2 -or
        $Body.properties.runbook -isnot [Collections.IDictionary] -or $Body.properties.runbook.Count -ne 1 -or $Body.properties.runbook.name -cne $Context.RunbookName -or
        $Body.properties.parameters -isnot [Collections.IDictionary] -or $Body.properties.parameters.Count -ne 6){throw 'Unsafe job payload shape.'}
    if(-not $Context.Contains('ParameterEncoding')){throw 'Legacy parameter encoding permits reconciliation only.'}
    $expected=AutomationJobParameters\Get-ValidationJobParameters -StorageAccountName $Context.StorageAccountName -ParameterEncoding $Context.ParameterEncoding
    foreach($key in $expected.Keys){if($Body.properties.parameters[$key] -isnot [string] -or $Body.properties.parameters[$key] -cne $expected[$key]){throw 'Unsafe job parameter.'}}
    return $true
}
Export-ModuleMember -Function Assert-ValidationContext,Assert-AutomationValidationPreflight,Assert-ValidationJobRequest
