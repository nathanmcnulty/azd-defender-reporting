#Requires -Version 7.6
Describe 'Actual publisher target boundaries' {
BeforeAll {
    $global:PublisherRealGetCommand = Microsoft.PowerShell.Core\Get-Command Get-Command -CommandType Cmdlet
    $sourceRoot = Split-Path $PSScriptRoot -Parent
    $script:root = Join-Path $TestDrive 'publisher-wrapper'
    New-Item $root -ItemType Directory -Force | Out-Null
    foreach($directory in @('scripts','contracts','vendor')) { Copy-Item (Join-Path $sourceRoot $directory) -Destination $root -Recurse }
    $script:subscription = '11111111-1111-4111-8111-111111111111'
    $script:tenant = '22222222-2222-4222-8222-222222222222'
    $script:target = @{ SubscriptionId = $subscription; TenantId = $tenant }
    $script:saved = @{}
    foreach ($name in @('AZURE_SUBSCRIPTION_ID','AZURE_TENANT_ID','COMPUTE_KIND','WEB_KIND','DASHBOARD_PACKAGE_MODE','computeKindResolved','webKindResolved','dashboardPackageModeResolved','CI','DEFENDER_REPORTING_PATH','DEFENDER_REPORTING_REPO','DEFENDER_REPORTING_REF')) {
        $script:saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    $env:CI = 'true'
    function global:az {
        $a = @($args); $global:LASTEXITCODE = 0
        $global:pub.Cli.Add(($a -join ' '))
        if ($a[0] -eq 'account' -and $a[1] -eq 'show') {
            if ($a -notcontains '--subscription') { return @{ id='99999999-9999-4999-8999-999999999999'; tenantId='88888888-8888-4888-8888-888888888888'; environmentName='AzureCloud'; state='Enabled' } | ConvertTo-Json }
            return @{ id=$global:pub.Subscription; tenantId=$global:pub.Tenant; environmentName='AzureCloud'; state='Enabled' } | ConvertTo-Json
        }
        if ($a[0] -eq 'account' -and $a[1] -eq 'get-access-token') {
            if ($a -notcontains '--subscription' -and $a -notcontains '--tenant') { throw 'Unscoped token tripwire.' }
            $global:pub.TokenRequests.Add(($a -join ' '))
            $tokenSub = if ($global:pub.TokenMismatch) { '99999999-9999-4999-8999-999999999999' } else { $global:pub.Subscription }
            $tokenTenant = if($global:pub.TokenTenantMismatch -or ($global:pub.GraphMismatch -and $a -contains '--tenant')){'99999999-9999-4999-8999-999999999999'}else{$global:pub.Tenant}
            return @{ accessToken='fixture-not-a-credential'; subscription=$tokenSub; tenant=$tokenTenant; expiresOn=[datetime]::UtcNow.AddHours(1).ToString('o') } | ConvertTo-Json
        }
        if ($a[0] -eq 'resource' -and $a[1] -eq 'list') {
            if ($a -notcontains '--subscription') { throw 'Unscoped discovery tripwire.' }
            $type=$a[[array]::IndexOf($a,'--resource-type')+1]
            $name=switch($type){'Microsoft.Web/sites'{'fn'} 'Microsoft.Automation/automationAccounts'{'aa'} 'Microsoft.App/containerApps'{'ca'} 'Microsoft.Storage/storageAccounts'{'reportstore'} default {throw 'Unexpected resource type'}}
            return ConvertTo-Json -InputObject @($name)
        }
        if ($a[0] -eq 'resource' -and $a[1] -eq 'show') {
            if ($a -notcontains '--subscription') { throw 'Ambient resource tripwire.' }
            $name=$a[[array]::IndexOf($a,'--name')+1]; $type=$a[[array]::IndexOf($a,'--resource-type')+1]
            $id="/subscriptions/$($global:pub.Subscription)/resourceGroups/rg/providers/$type/$name"
            if($global:pub.ResourceMismatch -and (-not $global:pub.ResourceMismatchType -or $type -eq $global:pub.ResourceMismatchType)){$id=$id.Replace('/rg/','/other/')}
            return @{id=$id;location='westus';deploymentContainerUrl='https://reportstore.blob.core.windows.net/packages'; fqdn='fixture.invalid';provisioningState='Succeeded';properties=@{primaryEndpoints=@{blob='https://reportstore.blob.core.windows.net/'}}} | ConvertTo-Json -Depth 5
        }
        if (($a[0] -eq 'storage' -and $a[1] -eq 'blob') -or ($a[0] -eq 'deployment' -and $a[2] -eq 'create')) {
            if ($a -notcontains '--subscription') { throw 'Unscoped mutation tripwire.' }
            $global:pub.Writes.Add(($a -join ' '))
            if($a -contains 'generate-sas'){ return 'fixture-sas' }
            return
        }
        throw "Unexpected CLI tripwire: $($a -join ' ')"
    }
    function global:Invoke-RestMethod {
        param($Uri,$Method,$Headers,$MaximumRedirection,$TimeoutSec,$Body)
        $global:pub.Requests.Add([pscustomobject]@{Uri=[string]$Uri;Method=[string]$Method;Body=$Body})
        if ($Uri -match '/subscriptions/[^/?]+\?api-version=2022-12-01$' -and $Method -eq 'Get') {
            $global:pub.Reads++
            if($global:pub.ReadFailure){throw 'Fixture fresh read failure'}
            if($global:pub.Malformed){return 'not an object'}
            $state=if($global:pub.Writes.Count -ge $global:pub.DisableAfter){'Disabled'}else{$global:pub.State}
            return @{id="/subscriptions/$($global:pub.ArmSubscription)";subscriptionId=$global:pub.ArmSubscription;tenantId=$global:pub.ArmTenant;state=$state}
        }
        if($Method -ne 'Get'){$global:pub.Writes.Add("HTTP $Method $Uri");return @{}}
        if($Uri -match '/runtimeEnvironments/PowerShell-76-AzAccounts/packages/Az.Accounts\?'){
            $global:pub.PackageReads++
            $state=if($global:pub.PackageMode -eq 'CreatedThenSucceeded' -and $global:pub.PackageReads -eq 1){'Created'}elseif($global:pub.PackageMode -eq 'Failed'){'Failed'}else{'Succeeded'}
            return @{properties=@{provisioningState=$state;version=$(if($global:pub.PackageMode -eq 'WrongVersion'){'5.3.4'}else{'5.5.0'})}}
        }
        if($Uri -match '/runtimeEnvironments/PowerShell-76-AzAccounts/packages\?'){
            $id=([string]$Uri -split '\?')[0] -replace '^https://management.azure.com',''
            $value=@(@{id=$id+'/Az.Accounts';name='Az.Accounts';properties=@{version='5.5.0';provisioningState='Succeeded';default=$false}})
            if($global:pub.PackageMode -eq 'ExtraPackage'){$value+=@{name='unexpected'}}
            return @{value=$value}
        }
        if($Uri -match '/runtimeEnvironments/PowerShell-76-AzAccounts\?'){
            $id=([string]$Uri -split '\?')[0] -replace '^https://management.azure.com',''
            return @{id=$id;properties=@{runtime=@{language='PowerShell';version='7.6'};defaultPackages=@{}}}
        }
        if($Uri -match 'jobSchedules'){return [pscustomobject]@{value=@()}}
        return @{properties=@{provisioningState='Succeeded'}}
    }
    function global:Invoke-WebRequest {
        param($Uri,$Method,$Headers,$MaximumRedirection,$TimeoutSec,$Body,$ContentType,$InFile,$UseBasicParsing,$SkipHttpErrorCheck)
        $global:pub.Requests.Add([pscustomobject]@{Uri=[string]$Uri;Method=[string]$Method;Body=$Body})
        if ($Method -eq 'GET' -and $Uri -match '/(schedules|jobSchedules)\?') {
            $collection=$Matches[1]
            if($global:pub.ScheduleReadFailure){throw 'Fixture schedule read failure'}
            $value=switch($global:pub.ScheduleState){
                'Malformed' {@{unexpected='missing value'}}
                'NullValue' {@{value=$null}}
                'ScalarValue' {@{value='not an array'}}
                'Paged' {@{value=@();nextLink='https://management.azure.com/more'}}
                'ArrayNextLink' {@{value=@();nextLink=@()}}
                'NumericNextLink' {@{value=@();nextLink=0}}
                'WhitespaceNextLink' {@{value=@();nextLink=' '}}
                'NullNextLink' {@{value=@();nextLink=$null}}
                'EmptyNextLink' {@{value=@();nextLink=''}}
                'ExistingSchedule' {if($collection -eq 'schedules'){@{value=@(@{name='existing'})}}else{@{value=@()}}}
                'ExistingLink' {if($collection -eq 'jobSchedules'){@{value=@(@{name='existing-link'})}}else{@{value=@()}}}
                default {@{value=@()}}
            }
            $content=switch($global:pub.ScheduleState){
                'ArrayRoot' {'[{"value":[]}]'}
                'NullRoot' {'null'}
                'InvalidJson' {'not-json'}
                default {ConvertTo-Json -InputObject $value -Depth 10}
            }
            $statusCode=switch($global:pub.ScheduleState){'PartialResponse'{206};'HttpFailure'{500};default{200}}
            return @{StatusCode=$statusCode;Content=$content}
        }
        if($Method -ne 'Get'){$global:pub.Writes.Add("HTTP $Method $Uri")}
        $value = if($Uri -match '/authConfigs/'){@{properties=@{platform=@{enabled=$false};identityProviders=$null}}}
            elseif($Uri -match '/applications' -and $Method -eq 'GET'){@{value=@()}}
            elseif($Uri -match '/servicePrincipals\?' -and $Uri -match '00000003'){@{value=@(@{id='graph-sp'})}}
            elseif($Uri -match '/servicePrincipals\?' -or $Uri -match '/oauth2PermissionGrants\?' -or $Uri -match '/appRoleAssignedTo\?'){@{value=@()}}
            elseif($Uri -match '/applications'){@{id='app';appId='33333333-3333-4333-8333-333333333333'}}
            elseif($Uri -match '/servicePrincipals'){@{id='sp';appId='33333333-3333-4333-8333-333333333333'}}
            else{@{}}
        return @{StatusCode=200;Content=($value|ConvertTo-Json -Depth 10)}
    }
}
BeforeEach {
    Mock Get-Command -MockWith { if ($Name -eq 'azd') { return $null }; & $global:PublisherRealGetCommand -Name $Name -ErrorAction SilentlyContinue }
    $global:pub = @{Subscription=$subscription;Tenant=$tenant;State='Enabled';Reads=0;DisableAfter=[int]::MaxValue;ReadFailure=$false;Malformed=$false;TokenMismatch=$false;TokenTenantMismatch=$false;GraphMismatch=$false;ArmSubscription=$subscription;ArmTenant=$tenant;ResourceMismatch=$false;ResourceMismatchType='';ScheduleState='Empty';ScheduleReadFailure=$false;Requests=[Collections.Generic.List[object]]::new();Cli=[Collections.Generic.List[string]]::new();Writes=[Collections.Generic.List[string]]::new();TokenRequests=[Collections.Generic.List[string]]::new()}
    $env:COMPUTE_KIND='functionapp';$env:WEB_KIND='none';$env:DASHBOARD_PACKAGE_MODE='auto'
    $global:pub.PackageMode='';$global:pub.PackageReads=0
    foreach($name in @('computeKindResolved','webKindResolved','dashboardPackageModeResolved')){[Environment]::SetEnvironmentVariable($name,$null)}
}
AfterAll {
    foreach($name in $script:saved.Keys){[Environment]::SetEnvironmentVariable($name,$script:saved[$name])}
    Remove-Item Function:/az,Function:/Invoke-RestMethod,Function:/Invoke-WebRequest
    Remove-Variable pub,PublisherRealGetCommand -Scope Global
}
    It 'rejects invalid target before writes for <Entry> (<Failure>)' -ForEach @(
        foreach($entry in @('Publish-FunctionAppPackage','Publish-AutomationRunbook','Publish-TemplateAssets','Publish-HostedSurface','Set-HostedSurfaceAuth','Publish-Deployment','Deploy')) {
            foreach($failure in @('Missing','MalformedId','WrongSubscription','WrongTenant','Disabled','MissingState','FailedRead','MalformedRead','TokenMismatch','TokenTenantMismatch','ArmSubscriptionMismatch','ArmTenantMismatch')) { @{Entry=$entry;Failure=$failure} }
        }
    ) {
        $parameters=@{}+$target
        switch($Failure){
            Missing {$parameters=@{SubscriptionId='';TenantId=''}}
            MalformedId {$parameters.SubscriptionId='not-a-guid'}
            WrongSubscription {$global:pub.Subscription='99999999-9999-4999-8999-999999999999'}
            WrongTenant {$global:pub.Tenant='99999999-9999-4999-8999-999999999999'}
            Disabled {$global:pub.State='Disabled'}
            MissingState {$global:pub.State=$null}
            FailedRead {$global:pub.ReadFailure=$true}
            MalformedRead {$global:pub.Malformed=$true}
            TokenMismatch {$global:pub.TokenMismatch=$true}
            TokenTenantMismatch {$global:pub.TokenTenantMismatch=$true}
            ArmSubscriptionMismatch {$global:pub.ArmSubscription='99999999-9999-4999-8999-999999999999'}
            ArmTenantMismatch {$global:pub.ArmTenant='99999999-9999-4999-8999-999999999999'}
        }
        switch($Entry){
            Publish-FunctionAppPackage {$parameters.ResourceGroupName='rg';$parameters.FunctionAppName='fn'}
            Publish-AutomationRunbook {$parameters.ResourceGroupName='rg';$parameters.AutomationAccountName='aa';$parameters.StorageAccountName='reportstore'}
            Publish-TemplateAssets {$parameters.StorageAccountName='reportstore';$parameters.ResourceGroupName='rg'}
            Publish-HostedSurface {$parameters.ResourceGroupName='rg';$parameters.ContainerAppName='ca';$parameters.StorageAccountName='reportstore';$env:WEB_KIND='containerapp'}
            Set-HostedSurfaceAuth {$parameters.ResourceGroupName='rg';$parameters.ContainerAppName='ca'}
            Publish-Deployment {$parameters.ResourceGroupName='rg';$parameters.FunctionAppName='fn';$parameters.StorageAccountName='reportstore'}
            Deploy {$parameters.SkipValidation=$true}
        }
        { & (Join-Path $root "scripts/$Entry.ps1") @parameters | Out-Null } | Should -Throw $(if($Failure -in @('Missing','MalformedId')){'*explicit*'}else{'*Enabled*'})
        $global:pub.Writes.Count | Should -Be 0
        @($global:pub.Cli | Where-Object {$_ -match '^(login|account set)' }).Count | Should -Be 0
    }
    It 'publishes Function with explicit target regardless of unrelated global default' {
        & "$root/scripts/Publish-FunctionAppPackage.ps1" @target -ResourceGroupName rg -FunctionAppName fn -SkipTemplatePublish | Out-Null
        $global:pub.Writes.Count | Should -Be 3
        foreach($write in $global:pub.Writes){$write | Should -Match "--subscription $subscription"}
        @($global:pub.Cli | Where-Object {$_ -match '^account set'}).Count | Should -Be 0
        (az account show | ConvertFrom-Json).id | Should -Be '99999999-9999-4999-8999-999999999999'
    }
    It 'rejects a wrong resource binding before the first write' {
        $global:pub.ResourceMismatch=$true
        {& "$root/scripts/Publish-FunctionAppPackage.ps1" @target -ResourceGroupName rg -FunctionAppName fn -SkipTemplatePublish | Out-Null} | Should -Throw '*resource binding*'
        $global:pub.Writes.Count | Should -Be 0
    }
    It 'rejects selected resource mismatch before orchestration or hosted template writes' -ForEach @(@{Entry='Publish-Deployment';Kind='functionapp'},@{Entry='Publish-Deployment';Kind='automation'},@{Entry='Publish-HostedSurface';Kind='functionapp'}) {
        $global:pub.ResourceMismatch=$true
        $env:COMPUTE_KIND=$Kind
        $global:pub.ResourceMismatchType=if($Entry -eq 'Publish-HostedSurface'){'Microsoft.App/containerApps'}elseif($Kind -eq 'automation'){'Microsoft.Automation/automationAccounts'}else{'Microsoft.Web/sites'}
        $env:WEB_KIND='containerapp'
        $parameters=@{}+$target
        $parameters.ResourceGroupName='rg';$parameters.ContainerAppName='ca';$parameters.StorageAccountName='reportstore'
        if($Entry -eq 'Publish-Deployment'){$parameters.FunctionAppName='fn';$parameters.AutomationAccountName='aa'}
        {& "$root/scripts/$Entry.ps1" @parameters | Out-Null} | Should -Throw '*resource binding*'
        $global:pub.Writes.Count | Should -Be 0
    }
    It 'stops Function after one write if fresh state becomes Disabled' {
        $global:pub.DisableAfter=1
        {& "$root/scripts/Publish-FunctionAppPackage.ps1" @target -ResourceGroupName rg -FunctionAppName fn -SkipTemplatePublish | Out-Null} | Should -Throw '*Enabled*'
        $global:pub.Writes.Count | Should -Be 1
    }
    It 'publishes Automation through bound shared tokens' {
        & "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -SkipTemplatePublish | Out-Null
        $global:pub.Writes.Count | Should -BeGreaterThan 8
        foreach($write in $global:pub.Writes){$write | Should -Match "/subscriptions/$subscription/"}
        $schedule=@($global:pub.Requests | Where-Object {$_.Method -eq 'PUT' -and $_.Uri -match '/schedules/DashboardPipeline-Daily\?'})
        $schedule.Count | Should -Be 1
        $payload=$schedule[0].Body | ConvertFrom-Json
        $payload.properties.isEnabled | Should -BeTrue
        $payload.properties.frequency | Should -Be 'Day'
        $payload.properties.interval | Should -Be 1
        @($global:pub.Requests | Where-Object {$_.Method -eq 'PUT' -and $_.Uri -match '/jobSchedules/'}).Count | Should -Be 1
    }
    It 'uses the locked version/hash in the actual publisher request and records the runtime contract' {
        $env:COMPUTE_KIND='automation'
        $result=& "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly -SkipTemplatePublish
        $import=@($global:pub.Requests | Where-Object {$_.Method -eq 'PUT' -and $_.Uri -match '/packages/Az.Accounts\?'})
        $import.Count | Should -Be 1
        $link=($import[0].Body | ConvertFrom-Json).properties.contentLink
        $link.uri | Should -BeExactly 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.5.0'
        $link.contentHash.value | Should -BeExactly '748a0abc2391b80385f25d41d740dc48d098cd2d6365bd70624fa165a4466044'
        $result.RuntimeContractSha256 | Should -Match '^[a-f0-9]{64}$'
        $result.AzAccountsVersion | Should -BeExactly '5.5.0'
    }
    It 'waits past Created and verifies import before publishing the runbook' {
        Mock Start-Sleep {}
        $global:pub.PackageMode='CreatedThenSucceeded'
        $env:COMPUTE_KIND='automation'
        & "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly -SkipTemplatePublish | Out-Null
        $global:pub.PackageReads | Should -Be 2
    }
    It 'publishes exactly the BOM-bearing runbook bytes bound by the manifest' {
        $env:COMPUTE_KIND='automation'
        $result=& "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly -SkipTemplatePublish
        $requests=@($global:pub.Requests | Where-Object {$_.Method -eq 'PUT' -and $_.Uri -match '/runbooks/Invoke-DashboardPipeline/draft/content\?'})
        $requests.Count | Should -Be 1
        $body=$requests[0].Body
        ($body -is [byte[]]) | Should -BeTrue
        ($body[0..2] -join ',') | Should -BeExactly '239,187,191'
        $bodyHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body)).ToLowerInvariant()
        $bodyHash | Should -BeExactly $result.RunbookSha256
        $manifest=Get-Content -LiteralPath $result.RunbookManifestPath -Raw | ConvertFrom-Json
        $manifest.runbookSizeBytes | Should -Be $body.LongLength
        $manifest.runbookSha256 | Should -BeExactly $bodyHash
        (Get-FileHash -LiteralPath $result.RunbookScriptPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -BeExactly $bodyHash
    }
    It 'stops publication on package failure or drift: <_>' -ForEach @('Failed','WrongVersion','ExtraPackage') {
        $global:pub.PackageMode=$_
        $env:COMPUTE_KIND='automation'
        {& "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly -SkipTemplatePublish | Out-Null} | Should -Throw
        @($global:pub.Requests | Where-Object {$_.Method -in @('PUT','POST') -and $_.Uri -match '/runbooks/'}).Count | Should -Be 0
    }
    It 'publishes manual-only Automation through <Entry> without changing schedules or starting jobs' -ForEach @(
        @{Entry='Publish-AutomationRunbook'},@{Entry='Publish-Deployment'},@{Entry='Deploy'}
    ) {
        $env:COMPUTE_KIND='automation'
        $parameters=@{}+$target
        $parameters.ResourceGroupName='rg';$parameters.ManualOnly=$true
        if($Entry -eq 'Deploy'){$parameters.SkipProvision=$true;$parameters.SkipValidation=$true}
        else {$parameters.AutomationAccountName='aa';$parameters.StorageAccountName='reportstore'}
        $result=@(& "$root/scripts/$Entry.ps1" @parameters) | Where-Object {$_.PSObject.Properties['ManualOnly']} | Select-Object -Last 1
        $result.ManualOnly | Should -BeTrue
        if($Entry -eq 'Publish-AutomationRunbook'){$result.ScheduleName | Should -Be ''}
        else {$result.AutomationPublish.ManualOnly | Should -Contain $true}
        @($global:pub.Writes | Where-Object {$_ -match '/(schedules|jobSchedules|jobs)(/|\?)'}).Count | Should -Be 0
        @($global:pub.Writes | Where-Object {$_ -match '/runbooks/Invoke-DashboardPipeline/publish\?'}).Count | Should -Be 1
        @($global:pub.Requests | Where-Object {$_.Method -eq 'GET' -and $_.Uri -match '/(schedules|jobSchedules)\?'}).Count | Should -BeGreaterOrEqual 2
    }
    It 'rejects unsafe manual-only scheduling state before any write through <Entry> (<State>)' -ForEach @(
        foreach($entry in @('Publish-AutomationRunbook','Publish-Deployment')){
            foreach($state in @('ExistingSchedule','ExistingLink','Malformed','NullValue','ScalarValue','Paged','FailedRead',
                'PartialResponse','ArrayRoot','ArrayNextLink','NumericNextLink','WhitespaceNextLink','NullRoot','InvalidJson','HttpFailure')){
                @{Entry=$entry;State=$state}
            }
        }
    ) {
        $env:COMPUTE_KIND='automation'
        $global:pub.ScheduleState=$State
        $global:pub.ScheduleReadFailure=($State -eq 'FailedRead')
        $expectedError=if($State -eq 'FailedRead'){'*Fixture schedule read failure*'}else{'*ManualOnly*'}
        {& "$root/scripts/$Entry.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly | Out-Null} | Should -Throw $expectedError
        $global:pub.Writes.Count | Should -Be 0
    }
    It 'accepts a complete empty manual-only inventory with <State>' -ForEach @(
        @{State='NullNextLink'},@{State='EmptyNextLink'}
    ) {
        $env:COMPUTE_KIND='automation'
        $global:pub.ScheduleState=$State
        $result=& "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly
        $result.ManualOnly | Should -BeTrue
        @($global:pub.Writes | Where-Object {$_ -match '/(schedules|jobSchedules|jobs)(/|\?)'}).Count | Should -Be 0
    }
    It 'rejects manual-only mode on <Compute>/<Web>/<Package> before any write through <Entry>' -ForEach @(
        foreach($entry in @('Publish-AutomationRunbook','Publish-Deployment','Deploy')){
            @{Entry=$entry;Compute='functionapp';Web='none';Package='auto'}
            @{Entry=$entry;Compute='automation';Web='containerapp';Package='auto'}
            @{Entry=$entry;Compute='automation';Web='none';Package='dual'}
        }
    ) {
        $env:COMPUTE_KIND=$Compute;$env:WEB_KIND=$Web;$env:DASHBOARD_PACKAGE_MODE=$Package
        {& "$root/scripts/$Entry.ps1" @target -ResourceGroupName rg -ManualOnly | Out-Null} | Should -Throw '*ManualOnly requires*'
        $global:pub.Writes.Count | Should -Be 0
    }
    It 'keeps manual-only BuildOnly and fully specified planning offline without claiming scheduling readback' {
        $env:COMPUTE_KIND='automation'
        & "$root/scripts/Publish-AutomationRunbook.ps1" -ManualOnly -BuildOnly | Out-Null
        $plan=& "$root/scripts/Publish-Deployment.ps1" -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -ManualOnly -PlanOnly
        $plan.ManualOnly | Should -BeTrue
        $plan.Operations | Should -Contain 'Publish Automation runbook without schedules (requires a schedule-free account)'
        $global:pub.Cli.Count | Should -Be 0
        $global:pub.Requests.Count | Should -Be 0
    }
    It 'stops Automation after one mutation even with a cached token' {
        $global:pub.DisableAfter=1
        {& "$root/scripts/Publish-AutomationRunbook.ps1" @target -ResourceGroupName rg -AutomationAccountName aa -StorageAccountName reportstore -SkipTemplatePublish | Out-Null} | Should -Throw '*Enabled*'
        $global:pub.Writes.Count | Should -Be 1
    }
    It 'publishes template files using the maintained bound path and stops on state change' {
        $templates=Join-Path $TestDrive templates;New-Item $templates -ItemType Directory -Force|Out-Null
        'one'|Set-Content "$templates/one.html";'two'|Set-Content "$templates/two.html"
        $global:pub.DisableAfter=1
        {& "$root/scripts/Publish-TemplateAssets.ps1" @target -ResourceGroupName rg -StorageAccountName reportstore -TemplatesPath $templates | Out-Null} | Should -Throw '*Enabled*'
        $global:pub.Writes.Count | Should -Be 1
    }
    It 'propagates explicit selectors through hosted orchestration and auth planning without uploads' {
        $env:WEB_KIND='containerapp'
        $result=& "$root/scripts/Publish-Deployment.ps1" @target -ResourceGroupName rg -FunctionAppName fn -ContainerAppName ca -StorageAccountName reportstore -PlanOnly
        $result.HostedSurfacePlan.AuthManagementMode | Should -Be 'Managed'
        $global:pub.Writes.Count | Should -Be 0
        $global:pub.Reads | Should -BeGreaterThan 4
    }
    It 'uses a tenant-bound Graph token for actual hosted auth mutations' {
        & "$root/scripts/Set-HostedSurfaceAuth.ps1" @target -ResourceGroupName rg -ContainerAppName ca | Out-Null
        $global:pub.Writes.Count | Should -BeGreaterThan 3
        @($global:pub.TokenRequests | Where-Object {$_ -match "--resource https://graph.microsoft.com --output json --only-show-errors --tenant $tenant"}).Count | Should -BeGreaterThan 0
    }
    It 'rejects mismatched Graph tenant metadata before hosted auth mutation' {
        $global:pub.GraphMismatch=$true
        {& "$root/scripts/Set-HostedSurfaceAuth.ps1" @target -ResourceGroupName rg -ContainerAppName ca | Out-Null} | Should -Throw '*matching the explicit Azure target*'
        $global:pub.Writes.Count | Should -Be 0
    }
    It 'stops hosted auth after the first mutation when subscription state changes' {
        $global:pub.DisableAfter=1
        {& "$root/scripts/Set-HostedSurfaceAuth.ps1" @target -ResourceGroupName rg -ContainerAppName ca | Out-Null} | Should -Throw '*Enabled*'
        $global:pub.Writes.Count | Should -Be 1
    }
    It 'keeps BuildOnly and fully specified non-hosted planning authentication-free' {
        & "$root/scripts/Publish-FunctionAppPackage.ps1" -BuildOnly | Out-Null
        & "$root/scripts/Publish-AutomationRunbook.ps1" -BuildOnly | Out-Null
        & "$root/scripts/Publish-Deployment.ps1" -ResourceGroupName rg -FunctionAppName fn -StorageAccountName reportstore -PlanOnly | Out-Null
        $global:pub.Cli.Count | Should -Be 0
        $global:pub.Reads | Should -Be 0
    }
    It 'runs the complete non-hosted orchestration for <Kind>' -ForEach @(@{Kind='functionapp'},@{Kind='automation'}) {
        $env:COMPUTE_KIND=$Kind
        $result=& "$root/scripts/Publish-Deployment.ps1" @target -ResourceGroupName rg -FunctionAppName fn -AutomationAccountName aa -StorageAccountName reportstore
        $result.TemplatePublish.PublisherContract | Should -Be 'build-layer-v1'
        $global:pub.Writes.Count | Should -BeGreaterThan 3
    }
    It 'runs Deploy publication with explicit selectors without requiring provision tooling' {
        & "$root/scripts/Deploy.ps1" @target -ResourceGroupName rg -SkipValidation -SkipProvision | Out-Null
        $global:pub.Writes.Count | Should -BeGreaterThan 3
    }
    It 'keys caches by resource subscription and tenant and revalidates each cache hit' {
        . "$root/scripts/Common-AzurePublish.ps1"
        Initialize-PublishTarget @target
        $uri="https://management.azure.com/subscriptions/$subscription/resourceGroups/rg"
        Get-AzAccessToken -Url $uri | Out-Null
        $first=$global:pub.TokenRequests.Count
        Get-AzAccessToken -Url $uri | Out-Null
        $global:pub.TokenRequests.Count | Should -Be ($first+1) # fresh guard token only
        $global:pub.Subscription='44444444-4444-4444-8444-444444444444'
        $global:pub.ArmSubscription=$global:pub.Subscription
        Initialize-PublishTarget -SubscriptionId $global:pub.Subscription -TenantId $tenant
        $before=$global:pub.TokenRequests.Count
        Get-AzAccessToken -Url "https://management.azure.com/subscriptions/$($global:pub.Subscription)/resourceGroups/rg" | Out-Null
        $global:pub.TokenRequests.Count | Should -Be ($before+2)
        $global:pub.State='Disabled'
        {Get-AzAccessToken -Url "https://management.azure.com/subscriptions/$($global:pub.Subscription)/resourceGroups/rg"} | Should -Throw '*Enabled*'
    }
}
