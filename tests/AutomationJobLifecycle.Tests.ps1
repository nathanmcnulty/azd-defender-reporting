BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../scripts/AutomationJobLifecycle.psm1') -Force
    function New-LifecycleArguments {
        $sim = $script:sim
        $arguments = @{
            TenantId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';SubscriptionId='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
            ResourceGroupName='rg-synthetic';AutomationAccountName='aa-synthetic';RunbookName='Invoke-DashboardPipeline';StorageAccountName='syntheticstore'
            JobId='11111111-2222-4333-8444-555555555555';FixtureSha256=('a'*64);RunbookSha256=('b'*64)
            ReceiptPath=$script:receipt;TimeoutSeconds=4;StopTimeoutSeconds=3;PollSeconds=1;MaxReadErrors=2
            Clock={ $sim.Time }.GetNewClosure()
            Sleep={param($seconds) $sim.Time += $seconds}.GetNewClosure()
            Guard={param($budget) $sim.Guards++; if($sim.Guards -ge $sim.GuardFailureAt){throw 'Disabled target'}; return (-not $sim.GuardReturnsFalse)}.GetNewClosure()
            Preflight={param($budget) $sim.Preflights++; if($sim.PreflightFails -or $sim.Preflights -ge $sim.PreflightFailureAt){throw 'Unexpected remote control/input/schedule'}; return $true}.GetNewClosure()
        }
        $receiptPath=$script:receipt
        $arguments.Request={
            param($method,$uri,$body,$budget)
            if($budget -le 0 -or $budget -gt 20){throw 'Invalid request time budget'}
            $sim.Calls.Add(@{method=$method;uri=$uri;budget=$budget})
            $sim.Time += 0.1
            if($method -eq 'PUT') {
                $saved=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
                if(-not $saved.submissionPossible -or -not $saved.submissionAttempted){throw 'Missing durable intent before submission'}
                $sim.Created=$true; $sim.Payload=$body
                if($sim.LockReceiptOnSubmit){$sim.LockedReceipt=[IO.File]::Open($receiptPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)}
                if($sim.SubmitThrows){throw 'Possibly accepted: sensitive-provider-detail'}
                return @{StatusCode=201;Body=$null}
            }
            if($method -eq 'POST') {
                if($uri -notmatch '/jobs/11111111-2222-4333-8444-555555555555/stop\?'){throw 'Wrong stop target'}
                $sim.Stopping=$true
                if($sim.StopThrows){throw 'Uncertain stop'}
                return @{StatusCode=200;Body=$null}
            }
            if($method -ne 'GET'){throw 'Unexpected mutation'}
            if(-not $sim.Created){return @{StatusCode=$sim.InitialStatus;Body=$null}}
            $sim.Reads++
            if($sim.ContainsKey('ExtraReadSeconds')){$sim.Time += $sim.ExtraReadSeconds}
            if($sim.Reads -le $sim.ReadFailures){return @{StatusCode=503;Body=$null}}
            if($sim.MissingAfterSubmit){return @{StatusCode=404;Body=$null}}
            $status=if($sim.Stopping){if($sim.StopNeverTerminal){'Stopping'}else{'Stopped'}}else{$sim.Status}
            $id=($uri -split '\?')[0] -replace '^https://management.azure.com',''
            if($sim.WrongId){$id=$id.Replace('/rg-synthetic/','/foreign/')}
            $runbook=if($sim.WrongRunbook){'foreign-runbook'}else{'Invoke-DashboardPipeline'}
            $parameters=@{}+$sim.Payload.properties.parameters
            if($sim.UnsafeParameters){$parameters.UseExistingExportsOnly='false'}
            return @{StatusCode=200;Body=@{id=$id;name='11111111-2222-4333-8444-555555555555';properties=@{status=$status;runbook=@{name=$runbook};parameters=$parameters}}}
        }.GetNewClosure()
        return $arguments
    }
}
Describe 'Exact-job single-submit lifecycle' {
    BeforeEach {
        $script:receipt=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json')
        $script:sim=@{Time=0.0;Calls=[Collections.Generic.List[object]]::new();Created=$false;Stopping=$false;Payload=$null;Reads=0;ReadFailures=0;Status='Completed';InitialStatus=404;SubmitThrows=$false;StopThrows=$false;StopNeverTerminal=$false;MissingAfterSubmit=$false;WrongId=$false;WrongRunbook=$false;UnsafeParameters=$false;Guards=0;GuardFailureAt=[int]::MaxValue;GuardReturnsFalse=$false;Preflights=0;PreflightFails=$false;PreflightFailureAt=[int]::MaxValue;GuardBudgets=[Collections.Generic.List[int]]::new();PreflightBudgets=[Collections.Generic.List[int]]::new();LockReceiptOnSubmit=$false;LockedReceipt=$null}
        $script:arguments=New-LifecycleArguments
    }
    AfterEach { if($null -ne $script:sim.LockedReceipt){$script:sim.LockedReceipt.Dispose()} }
    It 'persists intent before one PUT, fixes safe parameters and confirms execution completion' {
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-completed'
        $result.quiescenceConfirmed | Should -BeTrue
        $result.cleanupAllowed | Should -BeFalse
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
        $script:sim.Payload.properties.parameters.Count | Should -Be 6
        $script:sim.Payload.properties.parameters.UseExistingExportsOnly | Should -BeExactly 'true'
        $script:sim.Payload.properties.parameters.IncludeAdvancedHunting | Should -BeExactly 'false'
        $script:sim.Payload.properties.parameters.UseDirectMergeDeviceLookup | Should -BeExactly 'false'
        $script:sim.Guards | Should -Be 2
        $script:sim.Preflights | Should -Be 2
    }
    It 'reconciles an accepted PUT whose response was lost without resubmitting' {
        $script:sim.SubmitThrows=$true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-completed'
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
        Get-Content -LiteralPath $script:receipt -Raw | Should -Not -Match 'sensitive-provider-detail'
    }
    It 'never resubmits after uncertain submission and repeated 404 readback' {
        $script:sim.SubmitThrows=$true; $script:sim.MissingAfterSubmit=$true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.requiresReconciliation | Should -BeTrue
        $result.stopAttempted | Should -BeTrue
        $result.cleanupAllowed | Should -BeFalse
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
        @($script:sim.Calls | Where-Object method -eq 'POST').Count | Should -Be 1
    }
    It 'stops at an absolute deadline despite continuous Running responses and confirms terminal state' {
        $script:sim.Status='Running'
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-timeout'
        $result.stopAttempted | Should -BeTrue
        $result.quiescenceConfirmed | Should -BeTrue
        $result.terminalStatus | Should -Be 'Stopped'
        $script:sim.Time | Should -BeLessThan 8
    }
    It 'does not call a stop acknowledgement terminal quiescence' {
        $script:sim.Status='Running'; $script:sim.StopNeverTerminal=$true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.requiresReconciliation | Should -BeTrue
        $result.quiescenceConfirmed | Should -BeFalse
        $result.cleanupAllowed | Should -BeFalse
    }
    It 'does not count a late terminal response as completion within the deadline' {
        $script:sim.ExtraReadSeconds=5.0
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-timeout'
        $result.quiescenceConfirmed | Should -BeTrue
    }
    It 'confirms terminal readback even when the stop response was lost' {
        $script:sim.Status='Running'; $script:sim.StopThrows=$true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.quiescenceConfirmed | Should -BeTrue
        $result.terminalStatus | Should -Be 'Stopped'
    }
    It 'does not expand access or issue stop when the target guard fails before cancellation' {
        $script:sim.Status='Running'; $script:sim.GuardFailureAt=3
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.requiresReconciliation | Should -BeTrue
        @($script:sim.Calls | Where-Object method -eq 'POST').Count | Should -Be 0
    }
    It 'rejects false-returning guards before any request' {
        $script:sim.GuardReturnsFalse=$true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.submissionAttempted | Should -BeFalse
        $script:sim.Calls.Count | Should -Be 0
    }
    It 'fails preflight without submission' {
        $script:sim.PreflightFails=$true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.submissionAttempted | Should -BeFalse
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 0
    }
    It 'allows a longer preflight callback while guard and request budgets remain capped' {
        $script:arguments.TimeoutSeconds=600
        $script:arguments.PreflightTimeoutSeconds=120
        $sim=$script:sim
        $script:arguments.Guard={param($budget) $sim.GuardBudgets.Add($budget);return $true}.GetNewClosure()
        $script:arguments.Preflight={param($budget) $sim.PreflightBudgets.Add($budget);return $true}.GetNewClosure()
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-completed'
        $sim.PreflightBudgets.Count | Should -Be 2
        @($sim.PreflightBudgets | Where-Object {$_ -lt 1 -or $_ -gt 120}).Count | Should -Be 0
        @($sim.PreflightBudgets | Where-Object {$_ -gt 30}).Count | Should -Be 2
        $sim.PreflightBudgets[0] | Should -Be 120
        $sim.PreflightBudgets[1] | Should -Be 120
        @($sim.GuardBudgets | Where-Object {$_ -gt 30}).Count | Should -Be 0
        @($sim.Calls | Where-Object {$_.budget -gt 20}).Count | Should -Be 0
        $saved=Get-Content -LiteralPath $script:receipt -Raw | ConvertFrom-Json -AsHashtable
        $saved.binding.policy.preflightTimeoutSeconds | Should -Be 120
    }
    It 'caps each preflight callback by the remaining persisted execution time' {
        $script:arguments.TimeoutSeconds=10
        $script:arguments.PreflightTimeoutSeconds=120
        $sim=$script:sim
        $script:arguments.Guard={param($budget) $sim.GuardBudgets.Add($budget);if($sim.GuardBudgets.Count -eq 1){$sim.Time+=2};return $true}.GetNewClosure()
        $script:arguments.Preflight={param($budget) $sim.PreflightBudgets.Add($budget);$sim.Time+=1;return $true}.GetNewClosure()
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-completed'
        ($sim.PreflightBudgets -join ',') | Should -BeExactly '8,7'
        @($sim.Calls | Where-Object {$_.budget -gt 20}).Count | Should -Be 0
        @($sim.GuardBudgets | Where-Object {$_ -gt 20}).Count | Should -Be 0
    }
    It 'never reaches a job request when preflight returns after the execution deadline' {
        $script:arguments.TimeoutSeconds=4
        $script:arguments.PreflightTimeoutSeconds=120
        $sim=$script:sim
        $script:arguments.Guard={param($budget) $true}.GetNewClosure()
        $script:arguments.Preflight={param($budget) $sim.PreflightBudgets.Add($budget);$sim.Time+=5;return $true}.GetNewClosure()
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-timeout'
        $result.submissionAttempted | Should -BeFalse
        @($sim.Calls | Where-Object {$_.method -in @('GET','PUT','POST')}).Count | Should -Be 0
        $sim.PreflightBudgets[0] | Should -Be 4
    }
    It 'preserves legacy zero preflight policy bindings for reconciliation' {
        $script:arguments.PreflightTimeoutSeconds=0
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $saved=Get-Content -LiteralPath $script:receipt -Raw | ConvertFrom-Json -AsHashtable
        $saved.binding.policy.Contains('preflightTimeoutSeconds') | Should -BeFalse
        $legacyHash=$saved.bindingSha256
        $putCount=@($script:sim.Calls | Where-Object method -eq 'PUT').Count
        $script:sim.Reads=0
        $result=Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be $putCount
        $after=Get-Content -LiteralPath $script:receipt -Raw | ConvertFrom-Json -AsHashtable
        $after.bindingSha256 | Should -BeExactly $legacyHash
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
    }
    It 'rechecks identity immediately before PUT' {
        $script:sim.GuardFailureAt=2
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.submissionAttempted | Should -BeFalse
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 0
    }
    It 'rechecks remote preconditions immediately before PUT' {
        $script:sim.PreflightFailureAt=2
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.submissionAttempted | Should -BeFalse
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 0
    }
    It 'still stops and confirms the job if receipt updates fail after submission' {
        $script:sim.LockReceiptOnSubmit=$true; $script:sim.Status='Running'
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.evidenceWriteFailed | Should -BeTrue
        $result.stopAttempted | Should -BeTrue
        $result.quiescenceConfirmed | Should -BeTrue
        $result.cleanupAllowed | Should -BeFalse
    }
    It 'never overwrites an existing job or treats a failed absence check as 404' -ForEach @(200,403,500) {
        $script:sim.InitialStatus=$_
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.submissionAttempted | Should -BeFalse
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 0
    }
    It 'refuses a receipt collision before any provider request' {
        Set-Content -LiteralPath $script:receipt -Value 'existing work'
        { Invoke-ValidationJobLifecycle @script:arguments } | Should -Throw
        Get-Content -LiteralPath $script:receipt -Raw | Should -Match 'existing work'
        $script:sim.Calls.Count | Should -Be 0
    }
    It 'reports failed execution as failure with quiescence, not success' {
        $script:sim.Status='Failed'
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'execution-failed'
        $result.quiescenceConfirmed | Should -BeTrue
    }
    It 'stops a suspended job instead of calling it terminal' {
        $script:sim.Status='Suspended'
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.stopAttempted | Should -BeTrue
        $result.terminalStatus | Should -Be 'Stopped'
    }
    It 'fails closed on contradictory job bindings without stopping an unverified job' -ForEach @('WrongId','WrongRunbook','UnsafeParameters') {
        $script:sim[$_]= $true
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'binding-violation'
        $result.requiresReconciliation | Should -BeTrue
        @($script:sim.Calls | Where-Object method -eq 'POST').Count | Should -Be 0
    }
    It 'uses a bounded read-error budget, then stops and confirms the same job' {
        $script:sim.ReadFailures=2
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'read-budget-exhausted'
        $result.quiescenceConfirmed | Should -BeTrue
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
    }
    It 'reconciles the same persisted operation without another PUT and rechecks terminal state' {
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $script:sim.Reads=0; $script:sim.Status='Running'
        $result=Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
        $result.stopAttempted | Should -BeTrue
        $result.terminalStatus | Should -Be 'Stopped'
    }
    It 'rejects changed bindings before reconciliation requests' {
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $count=$script:sim.Calls.Count
        $script:arguments.FixtureSha256='c'*64
        { Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly } | Should -Throw '*match*'
        $script:sim.Calls.Count | Should -Be $count
    }
    It 'rejects a changed timeout policy during reconciliation' {
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $count=$script:sim.Calls.Count
        $script:arguments.TimeoutSeconds=60
        { Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly } | Should -Throw '*match*'
        $script:sim.Calls.Count | Should -Be $count
    }
    It 'rejects a changed preflight timeout policy during reconciliation before requests' {
        $script:arguments.PreflightTimeoutSeconds=120
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $count=$script:sim.Calls.Count
        $script:arguments.PreflightTimeoutSeconds=121
        { Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly } | Should -Throw '*match*'
        $script:sim.Calls.Count | Should -Be $count
    }
    It 'does not restart an expired original execution window when resuming' {
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $saved=Get-Content -LiteralPath $script:receipt -Raw | ConvertFrom-Json
        $oldStart=[DateTimeOffset]::UtcNow.AddMinutes(-2)
        $saved.createdAtUtc=$oldStart.ToString('o')
        $saved.executionDeadlineUtc=$oldStart.AddSeconds(4).ToString('o')
        $saved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:receipt
        $script:sim.Status='Running'; $before=$script:sim.Time
        $result=Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly
        $result.outcome | Should -Be 'execution-timeout'
        $result.stopAttempted | Should -BeTrue
        $result.quiescenceConfirmed | Should -BeTrue
        ($script:sim.Time-$before) | Should -BeLessThan 1
        @($script:sim.Calls | Where-Object method -eq 'PUT').Count | Should -Be 1
    }
    It 'still stops a Running job when a saved receipt already has 2000 events' {
        $first=Invoke-ValidationJobLifecycle @script:arguments
        $saved=Get-Content -LiteralPath $script:receipt -Raw | ConvertFrom-Json
        $saved.events=@(1..2000 | ForEach-Object { @{atUtc='2026-10-21T00:00:00Z';code='job-Running'} })
        $saved | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:receipt
        $script:sim.Status='Running'
        $result=Invoke-ValidationJobLifecycle @script:arguments -ReconcileOnly
        $result.stopAttempted | Should -BeTrue
        $result.quiescenceConfirmed | Should -BeTrue
        $result.cleanupAllowed | Should -BeFalse
        $result.eventsOmitted | Should -BeGreaterThan 0
        $after=Get-Content -LiteralPath $script:receipt -Raw | ConvertFrom-Json
        $after.events.Count | Should -BeLessOrEqual 2000
    }
    It 'never logs unknown provider status text' {
        $script:sim.Status='unknown-sensitive-value'
        $result=Invoke-ValidationJobLifecycle @script:arguments
        $result.outcome | Should -Be 'unknown-status'
        Get-Content -LiteralPath $script:receipt -Raw | Should -Not -Match 'unknown-sensitive-value'
    }
}
