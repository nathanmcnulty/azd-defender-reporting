BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationValidationAdapter.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationValidationPreflight.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationRuntimeContract.psm1') -Force
    if(-not ('AzdValidationTests.HttpHandler' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
namespace AzdValidationTests {
    public sealed class HttpHandler : HttpMessageHandler {
        public string Mode = "Success";
        public int Calls;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) {
            Calls++;
            if (Mode == "Timeout") await Task.Delay(30000, token);
            var response = new HttpResponseMessage(Mode == "Redirect" ? HttpStatusCode.Redirect : HttpStatusCode.OK);
            if (Mode == "Redirect") response.Headers.Location = new Uri("https://example.invalid/foreign");
            response.Content = Mode == "Oversize" ? new ByteArrayContent(new byte[1048577]) : new StringContent("{\"valid\":true}");
            return response;
        }
    }
}
'@
    }
    function Get-TestHash([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
    function New-TestArtifact([string]$Name,[string]$Text){$bytes=[Text.Encoding]::UTF8.GetBytes($Text);return @{name=$Name;bytes=$bytes.Length;sha256=(Get-TestHash $bytes)}}
    function New-AdapterFixture {
        $script:content=@{'Machines_Current.json.gz'='machines';'VulnExport_100_2026-10-21.json.gz'='rows';'dashboard.html'='<html>synthetic</html>'}
        $artifacts=@((New-TestArtifact 'Machines_Current.json.gz' 'machines'),(New-TestArtifact 'VulnExport_100_2026-10-21.json.gz' 'rows'))
        $identity=@($artifacts | Sort-Object name -CaseSensitive | ForEach-Object {'{0}|{1}|{2}' -f $_.name,$_.bytes,$_.sha256}) -join "`n"
        $script:context=@{TenantId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';SubscriptionId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';ResourceGroupName='rg-synthetic';AutomationAccountName='aa-synthetic';RunbookName='Invoke-DashboardPipeline';StorageAccountName='syntheticstore';JobId='11111111-2222-4333-8444-555555555555';AutomationPrincipalId='22222222-2222-4222-8222-222222222222';ExpectedUserName='operator@synthetic.invalid';RunbookSha256=(Get-TestHash ([Text.Encoding]::UTF8.GetBytes('param()')));FixtureSha256=(Get-TestHash ([Text.Encoding]::UTF8.GetBytes($identity)));Artifacts=$artifacts;Templates=@((New-TestArtifact 'dashboard.html' '<html>synthetic</html>'))}
        $script:jobUri="https://management.azure.com/subscriptions/$($script:context.SubscriptionId)/resourceGroups/rg-synthetic/providers/Microsoft.Automation/automationAccounts/aa-synthetic/jobs/$($script:context.JobId)?api-version=2024-10-23"
        $script:context.RuntimeContractSha256=(AutomationRuntimeContract\Get-AutomationRuntimeContract).Sha256
        $script:payload=@{properties=@{runbook=@{name='Invoke-DashboardPipeline'};parameters=@{StorageAccountName='syntheticstore';UseExistingExportsOnly='true';IncludeAdvancedHunting='false';UseDirectMergeDeviceLookup='false';DashboardDeliveryMode='SelfContained';Export='BlobStorage'}}}
        $script:fault=''
        $script:reads=[Collections.Generic.List[object]]::new()
    }
    function Invoke-TestPreflight {
        $read={
            param($uri,$audience,$method)
            $script:reads.Add(@{uri=$uri;audience=$audience;method=$method})
            if($method -cnotin @('GET','HEAD')){throw 'Mutation tripwire'}
            $path=([uri]$uri).AbsolutePath
            $body=$null
            $status=200
            if($method -eq 'HEAD'){$status=if($script:fault -eq 'ControlPresent'){200}elseif($script:fault -eq 'ControlDenied'){403}else{404};return @{StatusCode=$status;Bytes=[byte[]]@()}}
            if($audience -eq 'ARM') {
                $body=if($path -like '*/automationAccounts/aa-synthetic'){@{id=$path;identity=@{principalId=$(if($script:fault -eq 'Principal'){'33333333-3333-4333-8333-333333333333'}else{$script:context.AutomationPrincipalId})}}}
                    elseif($path -like '*/storageAccounts/syntheticstore'){@{id=$path;properties=@{primaryEndpoints=@{blob=$(if($script:fault -eq 'StorageEndpoint'){'https://foreign.blob.core.windows.net/'}else{'https://syntheticstore.blob.core.windows.net/'})}}}}
                    elseif($path -match '/(schedules|jobSchedules|jobs)$'){
                        $collection=$Matches[1]
                        $value=@()
                        if($script:fault -eq 'Schedule' -and $collection -eq 'schedules'){$value=@(@{name='unexpected'})}
                        if($script:fault -eq 'Link' -and $collection -eq 'jobSchedules'){$value=@(@{name='unexpected'})}
                        if($script:fault -eq 'ActiveJob' -and $collection -eq 'jobs'){$value=@(@{properties=@{status='Running'}})}
                        if($script:fault -eq 'BadCollection'){$value=$null}
                        $listing=@{value=$value}
                        if($script:fault -eq 'Paged'){$listing.nextLink='https://management.azure.com/more'}
                        if($script:fault -eq 'NumericLink'){$listing.nextLink=0}
                        if($script:fault -eq 'BooleanLink'){$listing.nextLink=$false}
                        if($script:fault -eq 'ArrayLink'){$listing.nextLink=@()}
                        if($script:fault -eq 'WhitespaceLink'){$listing.nextLink=' '}
                        $listing
                    }
                    elseif($path -like '*/runbooks/Invoke-DashboardPipeline'){@{id=$path;properties=@{state=$(if($script:fault -eq 'Draft'){'New'}else{'Published'});runbookType='PowerShell';runtimeEnvironment=$(if($script:fault -eq 'RuntimeBinding'){'foreign-runtime'}else{'PowerShell-76-AzAccounts'})}}}
                    elseif($path -like '*/runtimeEnvironments/PowerShell-76-AzAccounts'){@{id=$path;properties=@{runtime=@{language='PowerShell';version=$(if($script:fault -eq 'RuntimeVersion'){'7.4'}else{'7.6'})};defaultPackages=@{}}}}
                    elseif($path -like '*/runtimeEnvironments/PowerShell-76-AzAccounts/packages'){@{value=@(@{id=$path+'/Az.Accounts';name='Az.Accounts';properties=@{default=$false;sizeInBytes=9999717;provisioningState='Succeeded';version=$(if($script:fault -eq 'PackageVersion'){'5.3.4'}else{'5.5.0'})}})}}
                    elseif($path -like '*/content'){
                        $bytes=[Text.Encoding]::UTF8.GetBytes($(if($script:fault -eq 'RunbookHash'){'changed'}else{'param()'}))
                        return @{StatusCode=200;Bytes=$bytes}
                    }else{throw 'Unexpected ARM read'}
                $bytes=[Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 12 -Compress))
                return @{StatusCode=$status;Bytes=$bytes}
            }
            if(([uri]$uri).Query -like '*comp=list*') {
                $container=$path.Trim('/')
                $entries=@(if($container -eq 'exports'){$script:context.Artifacts}else{$script:context.Templates})
                $blobs=(@($entries | ForEach-Object {"<Blob><Name>$($_.name)</Name></Blob>"}) -join '')
                if($script:fault -eq 'ExtraBlob'){$blobs+='<Blob><Name>unexpected.json</Name></Blob>'}
                if($script:fault -eq 'MissingBlob'){$blobs=''}
                $marker=if($script:fault -eq 'BlobPaged'){'more'}else{''}
                $xml="<EnumerationResults><Blobs>$blobs</Blobs><NextMarker>$marker</NextMarker></EnumerationResults>"
                if($script:fault -eq 'Dtd'){$xml='<!DOCTYPE x [<!ENTITY e SYSTEM "file:///does-not-exist">]><EnumerationResults><Blobs>&e;</Blobs><NextMarker/></EnumerationResults>'}
                return @{StatusCode=200;Bytes=[Text.Encoding]::UTF8.GetBytes($xml)}
            }
            $name=($path.Trim('/') -split '/',2)[1]
            $text=$script:content[$name]
            if($script:fault -eq 'ArtifactHash'){$text=$text.ToUpperInvariant()}
            if($script:fault -eq 'ArtifactSize'){$text+='extra'}
            return @{StatusCode=200;Bytes=[Text.Encoding]::UTF8.GetBytes($text)}
        }
        Assert-AutomationValidationPreflight -Context $script:context -Read $read
    }
}
Describe 'Bounded HTTP response path with an in-memory handler' {
    BeforeEach {
        $script:httpHandler=[AzdValidationTests.HttpHandler]::new()
        $script:httpClient=[Net.Http.HttpClient]::new($script:httpHandler)
        $script:sendCore=[AzdValidation.BoundedIO].GetMethod('SendCore',[Reflection.BindingFlags]'NonPublic,Static')
    }
    AfterEach {$script:httpClient.Dispose()}
    It 'returns one response without retrying a redirect status' {
        $script:httpHandler.Mode='Redirect'
        $task=$script:sendCore.Invoke($null,@($script:httpClient,'GET',[uri]'https://management.azure.com/synthetic','synthetic-token',$null,2))
        $result=$task.GetAwaiter().GetResult()
        $result.StatusCode | Should -Be 302
        $script:httpHandler.Calls | Should -Be 1
    }
    It 'rejects an oversized response stream' {
        $script:httpHandler.Mode='Oversize'
        {$task=$script:sendCore.Invoke($null,@($script:httpClient,'GET',[uri]'https://management.azure.com/synthetic','synthetic-token',$null,2));$task.GetAwaiter().GetResult()} | Should -Throw '*Response bound*'
    }
    It 'cancels an in-flight HTTP operation within its own request budget' {
        $script:httpHandler.Mode='Timeout'
        $watch=[Diagnostics.Stopwatch]::StartNew()
        {$task=$script:sendCore.Invoke($null,@($script:httpClient,'GET',[uri]'https://management.azure.com/synthetic','synthetic-token',$null,1));$task.GetAwaiter().GetResult()} | Should -Throw
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 4
        $script:httpHandler.Calls | Should -Be 1
    }
    It 'rejects a non-HTTPS or credential-bearing URI before the handler receives it' -ForEach @('http://management.azure.com/synthetic','https://user@management.azure.com/synthetic') {
        {$task=$script:sendCore.Invoke($null,@($script:httpClient,'GET',[uri]$_,'synthetic-token',$null,1));$task.GetAwaiter().GetResult()} | Should -Throw
        $script:httpHandler.Calls | Should -Be 0
    }
}
Describe 'Exact remote synthetic preflight and request policy' {
    BeforeEach {New-AdapterFixture}
    It 'verifies account, code, empty scheduling, control absence and every exact blob hash' {
        Invoke-TestPreflight | Should -BeTrue
        @($script:reads | Where-Object method -notin @('GET','HEAD')).Count | Should -Be 0
        @($script:reads | Where-Object uri -like '*comp=list*').Count | Should -Be 2
    }
    It 'rejects an unqualified remote state: <_>' -ForEach @('Principal','StorageEndpoint','Schedule','Link','ActiveJob','BadCollection','Paged','NumericLink','BooleanLink','ArrayLink','WhitespaceLink','Draft','RunbookHash','ControlPresent','ControlDenied','ExtraBlob','MissingBlob','BlobPaged','Dtd','ArtifactHash','ArtifactSize') {
        $script:fault=$_
        $expectedFailure=switch($script:fault){
            'Principal'{'*account identity*'} 'StorageEndpoint'{'*Storage binding*'}
            'Schedule'{'*schedule-free*'} 'Link'{'*schedule-free*'} 'ActiveJob'{'*active job*'}
            'BadCollection'{'*Incomplete Automation*'} 'Paged'{'*Incomplete Automation*'}
            'NumericLink'{'*Incomplete Automation*'} 'BooleanLink'{'*Incomplete Automation*'} 'ArrayLink'{'*Incomplete Automation*'} 'WhitespaceLink'{'*Incomplete Automation*'}
            'Draft'{'*runbook metadata*'} 'RunbookHash'{'*runbook bytes*'}
            'ControlPresent'{'*Control-blob absence*'} 'ControlDenied'{'*Control-blob absence*'}
            'ExtraBlob'{'*blob count*'} 'MissingBlob'{'*blob count*'} 'BlobPaged'{'*blob enumeration*'}
            'Dtd'{'*DTD*'} 'ArtifactHash'{'*artifact hash*'} 'ArtifactSize'{'*artifact size*'}
        }
        {Invoke-TestPreflight} | Should -Throw $expectedFailure
    }
    It 'rejects a mismatched approved fixture identity before reads' {
        $script:context.FixtureSha256='a'*64
        {Invoke-TestPreflight} | Should -Throw '*fixture identity*'
        $script:reads.Count | Should -Be 0
    }
    It 'rejects runtime or package drift before job submission' -ForEach @('RuntimeBinding','RuntimeVersion','PackageVersion') {
        $script:fault=$_
        {Invoke-TestPreflight} | Should -Throw
    }
    It 'rejects a changed local runtime contract binding before any read' {
        $script:context.RuntimeContractSha256='a'*64
        {Invoke-TestPreflight} | Should -Throw '*Runtime contract binding*'
        $script:reads.Count | Should -Be 0
    }
    It 'supports the locked release nested dashboard template modules without allowing traversal' {
        $script:context.Templates=@((New-TestArtifact 'dashboard/00-core.js' 'module'))
        $script:content['dashboard/00-core.js']='module'
        Invoke-TestPreflight | Should -BeTrue
        $script:context.Templates[0].name='dashboard/../escape.js'
        {Assert-ValidationContext $script:context} | Should -Throw '*artifact identity*'
    }
    It 'rejects unknown context fields instead of accepting credential or policy overrides' {
        $script:context.Unexpected='not-a-credential'
        {Assert-ValidationContext $script:context} | Should -Throw '*context fields*'
    }
    It 'rejects unsafe template paths with ordinary integer byte sizes' -ForEach @('../escape.js','dashboard/../escape.js','dashboard\escape.js','/absolute.js','dashboard//module.js','dashboard/module.js?query=true') {
        $script:context.Templates[0].name=$_
        {Assert-ValidationContext $script:context} | Should -Throw '*artifact identity*'
    }
    It 'plans the exact job offline without authenticating or writing a receipt' {
        $planContext=Join-Path $TestDrive 'approved-context.json'
        $planReceipt=Join-Path $TestDrive 'unwritten-receipt.json'
        $script:context | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planContext
        $plan=& (Join-Path $PSScriptRoot '../scripts/Invoke-SyntheticAutomationValidation.ps1') -ContextPath $planContext -ReceiptPath $planReceipt
        $plan.mode | Should -Be 'offline-plan'
        $plan.providerAccessPerformed | Should -BeFalse
        $plan.cleanupAllowed | Should -BeFalse
        $plan.jobResourceId | Should -Match $script:context.JobId
        Test-Path -LiteralPath $planReceipt | Should -BeFalse
    }
    It 'accepts only one bound job GET/PUT and same-job stop' {
        Assert-ValidationJobRequest $script:context 'GET' $script:jobUri $null | Should -BeTrue
        Assert-ValidationJobRequest $script:context 'PUT' $script:jobUri $script:payload | Should -BeTrue
        Assert-ValidationJobRequest $script:context 'POST' ($script:jobUri -replace '\?','/stop?') $null | Should -BeTrue
    }
    It 'rejects a different scope, job, host, query, method or credentials in the URI' -ForEach @('Scope','Job','Host','Query','Delete','UserInfo') {
        $case=$_
        $uri=switch($case){'Scope'{$script:jobUri.Replace('/rg-synthetic/','/foreign/')} 'Job'{$script:jobUri.Replace($script:context.JobId,'33333333-3333-4333-8333-333333333333')} 'Host'{$script:jobUri.Replace('management.azure.com','example.invalid')} 'Query'{$script:jobUri+'&extra=true'} 'UserInfo'{$script:jobUri.Replace('https://','https://user@')} default{$script:jobUri}}
        $method=if($case -eq 'Delete'){'DELETE'}else{'GET'}
        {Assert-ValidationJobRequest $script:context $method $uri $null} | Should -Throw
    }
    It 'rejects Defender API access parameters and additional payload fields' {
        $script:payload.properties.parameters.UseExistingExportsOnly='false'
        {Assert-ValidationJobRequest $script:context 'PUT' $script:jobUri $script:payload} | Should -Throw '*parameter*'
        $script:payload.properties.parameters.UseExistingExportsOnly='true'
        $script:payload.properties.runOn='unexpected'
        {Assert-ValidationJobRequest $script:context 'PUT' $script:jobUri $script:payload} | Should -Throw '*shape*'
    }
    It 'rejects invalid job requests through the factory without launching a worker' {
        $adapter=New-AutomationValidationAdapter $script:context
        {& $adapter.Request 'DELETE' $script:jobUri $null 1} | Should -Throw '*allowlist*'
    }
}
Describe 'Real child-process supervision without Azure' {
    BeforeEach {$script:worker=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.ps1')}
    It 'accepts a single bounded strict JSON response' {
        Set-Content -LiteralPath $script:worker -Value '[Console]::Out.Write(''{"ok":true,"result":true}'')'
        Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 5 | Should -BeTrue
    }
    It 'rejects malformed transport response types rather than coercing them' -ForEach @('"200"','200.5','true','99','600') {
        Set-Content -LiteralPath $script:worker -Value ('[Console]::Out.Write(''{"ok":true,"result":{"StatusCode":'+$_+',"Body":null}}'')')
        {Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 5} | Should -Throw '*worker failed*'
    }
    It 'round-trips real child JSON responses through the lifecycle single-submit path' {
        New-AdapterFixture
        Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationJobLifecycle.psm1') -Force
        Set-Content -LiteralPath $script:worker -Value @'
$message=[Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
if($message.method -eq 'PUT'){
    $message.body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $message.state
    $response=@{StatusCode=201;Body=$null}
}elseif($message.method -eq 'GET' -and -not (Test-Path -LiteralPath $message.state)){
    $response=@{StatusCode=404;Body=$null}
}elseif($message.method -eq 'GET'){
    $submitted=Get-Content -LiteralPath $message.state -Raw | ConvertFrom-Json -AsHashtable
    $response=@{StatusCode=200;Body=@{id=($message.uri -split '\?')[0].Replace('https://management.azure.com','');name=$message.job;properties=@{status='Completed';runbook=$submitted.properties.runbook;parameters=$submitted.properties.parameters}}}
}else{throw 'Unexpected request'}
[Console]::Out.Write((@{ok=$true;result=$response} | ConvertTo-Json -Depth 20 -Compress))
'@
        $worker=$script:worker
        $state=Join-Path $TestDrive 'submitted.json'
        $context=$script:context
        $seen=[Collections.Generic.List[int]]::new()
        $request={param($method,$uri,$body,$budget)
            Assert-ValidationJobRequest $context $method $uri $body | Out-Null
            $response=Invoke-BoundedValidationChild -ScriptPath $worker -Message @{method=$method;uri=$uri;body=$body;job=$context.JobId;state=$state} -TimeoutSeconds 5
            if($response.StatusCode -isnot [int]){throw 'Unnormalized status'}
            $seen.Add($response.StatusCode)
            return $response
        }.GetNewClosure()
        $arguments=@{}
        foreach($key in @('TenantId','SubscriptionId','ResourceGroupName','AutomationAccountName','RunbookName','StorageAccountName','JobId','FixtureSha256','RunbookSha256')){$arguments[$key]=$context[$key]}
        $arguments.ReceiptPath=Join-Path $TestDrive 'roundtrip-receipt.json'
        $arguments.TimeoutSeconds=30;$arguments.StopTimeoutSeconds=10;$arguments.PollSeconds=1
        $arguments.Guard={param($budget) $true};$arguments.Preflight={param($budget) $true};$arguments.Request=$request
        $result=Invoke-ValidationJobLifecycle @arguments
        $result.outcome | Should -Be 'execution-completed'
        $result.quiescenceConfirmed | Should -BeTrue
        $result.cleanupAllowed | Should -BeFalse
        ($seen -join ',') | Should -BeExactly '404,201,200'
    }
    It 'rejects duplicate-property and array protocol responses' -ForEach @('{"ok":true,"ok":false,"result":true}','[]') {
        Set-Content -LiteralPath $script:worker -Value ('[Console]::Out.Write('''+$_+''')')
        {Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 5} | Should -Throw '*worker failed*'
    }
    It 'sanitizes worker stderr and failure rather than returning provider details' {
        Set-Content -LiteralPath $script:worker -Value '[Console]::Error.Write("sensitive-fixture-detail");exit 1'
        try{Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 5;throw 'Expected failure'}catch{$_.Exception.Message | Should -Match 'worker failed';$_.Exception.Message | Should -Not -Match 'sensitive-fixture-detail'}
    }
    It 'kills a worker at its total operation deadline' {
        Set-Content -LiteralPath $script:worker -Value 'Start-Sleep -Seconds 30'
        $watch=[Diagnostics.Stopwatch]::StartNew()
        {Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 1} | Should -Throw '*worker failed*'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
    }
    It 'bounds stdout before accepting protocol data' {
        Set-Content -LiteralPath $script:worker -Value '[Console]::Out.Write((''x'' * 2200000))'
        {Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 5} | Should -Throw '*worker failed*'
    }
    It 'kills the timed-out worker process tree, including a live descendant' {
        $pidPath=Join-Path $TestDrive 'worker-descendant.pid'
        $pidLiteral=$pidPath.Replace("'","''")
        $childSource=@'
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME $(if($IsWindows){'pwsh.exe'}else{'pwsh'})))
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.ArgumentList.Add('-NoProfile');$start.ArgumentList.Add('-NonInteractive');$start.ArgumentList.Add('-Command');$start.ArgumentList.Add('Start-Sleep -Seconds 30')
$child=[Diagnostics.Process]::Start($start)
[IO.File]::WriteAllText('__PID_PATH__',[string]$child.Id)
Start-Sleep -Seconds 30
'@
        Set-Content -LiteralPath $script:worker -Value ($childSource.Replace('__PID_PATH__',$pidLiteral))
        {Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 3} | Should -Throw '*worker failed*'
        Test-Path -LiteralPath $pidPath | Should -BeTrue
        $descendantId=[int](Get-Content -LiteralPath $pidPath -Raw)
        $running=$false
        try{$descendant=[Diagnostics.Process]::GetProcessById($descendantId);$running=-not $descendant.HasExited;$descendant.Dispose()}catch{}
        $running | Should -BeFalse
    }
    It 'rejects an actual worker out-of-scope request before authentication' {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive 'fake-cli'
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message @{action='Request';context=$script:context;method='DELETE';uri=$script:jobUri;body=$null;budget=10} -TimeoutSeconds 10} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeFalse
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'accepts a valid serialized budget and reaches only the fake CLI guard boundary' -ForEach @(1,20,30) {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive ('valid-cli-'+$_)
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            $budget=$_
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message @{action='Guard';context=$script:context;budget=$budget} -TimeoutSeconds 10} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeTrue
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'rejects invalid serialized budgets before reaching even the fake CLI' -ForEach @('20',20.5,$true,0,31) {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive ('invalid-cli-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            $budget=$_
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message @{action='Guard';context=$script:context;budget=$budget} -TimeoutSeconds 10} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeFalse
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'keeps Guard and Request worker budgets at or below 30 seconds' -ForEach @('Guard','Request') {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive ('over-budget-cli-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            $action=$_
            $message=@{action=$action;context=$script:context;budget=31}
            if($action -eq 'Request'){$message.method='GET';$message.uri=$script:jobUri;$message.body=$null}
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message $message -TimeoutSeconds 35} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeFalse
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'accepts a preflight callback budget above 30 only with a request budget at or below 30' {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive 'preflight-long-budget-cli'
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message @{action='Preflight';context=$script:context;budget=31;requestBudget=30} -TimeoutSeconds 35} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeTrue
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'rejects preflight request budgets outside 1 through 30 before CLI access' -ForEach @(0,31) {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive ('invalid-preflight-request-budget-'+$_)
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            $requestBudget=$_
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message @{action='Preflight';context=$script:context;budget=31;requestBudget=$requestBudget} -TimeoutSeconds 35} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeFalse
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'rejects an extended preflight budget when its per-request budget is missing' {
        New-AdapterFixture
        $tripwireDirectory=Join-Path $TestDrive 'missing-preflight-request-budget-cli'
        New-Item -ItemType Directory -Path $tripwireDirectory -Force | Out-Null
        $tripwireMarker=Join-Path $tripwireDirectory 'called.txt'
        Set-Content -LiteralPath (Join-Path $tripwireDirectory 'az.cmd') -Value "@echo off`necho called > `"$tripwireMarker`"`nexit /b 1"
        $oldAdapterPath=$env:PATH
        try {
            $env:PATH=$tripwireDirectory+';'+$env:PATH
            $actualWorker=Join-Path $PSScriptRoot '../scripts/AutomationValidationWorker.ps1'
            {Invoke-BoundedValidationChild -ScriptPath $actualWorker -Message @{action='Preflight';context=$script:context;budget=31} -TimeoutSeconds 35} | Should -Throw '*worker failed*'
            Test-Path -LiteralPath $tripwireMarker | Should -BeFalse
        } finally {$env:PATH=$oldAdapterPath}
    }
    It 'allows a real supervised offline child to run for 31 seconds within its 35-second callback bound' {
        Set-Content -LiteralPath $script:worker -Value "Start-Sleep -Seconds 31`n[Console]::Out.Write('{`"ok`":true,`"result`":true}')"
        $watch=[Diagnostics.Stopwatch]::StartNew()
        Invoke-BoundedValidationChild -ScriptPath $script:worker -Message @{action='offline-test'} -TimeoutSeconds 35 | Should -BeTrue
        $watch.Elapsed.TotalSeconds | Should -BeGreaterOrEqual 31
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 35
    }
}
