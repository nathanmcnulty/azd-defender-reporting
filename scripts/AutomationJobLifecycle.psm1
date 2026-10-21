#Requires -Version 7.6
Set-StrictMode -Version Latest

function Invoke-ValidationJobLifecycle {
    <#
    .SYNOPSIS
    Reconciles one explicitly bound synthetic validation job through bounded adapters.
    .DESCRIPTION
    Persists intent before a single submission, observes the same job, and attempts
    bounded stop with terminal readback on failure or timeout. Adapters must enforce
    fresh target checks and approved remote preconditions; no live adapter is supplied.
    ReconcileOnly suppresses submission, but can stop the exact job in the saved intent.
    Execution completion is not functional report acceptance or cleanup approval.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$TenantId,
        [Parameter(Mandatory)][guid]$SubscriptionId,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9_().-]{1,90}\z')][string]$ResourceGroupName,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9-]{0,62}\z')][string]$AutomationAccountName,
        [Parameter(Mandatory)][ValidatePattern('\A[A-Za-z0-9][A-Za-z0-9_-]{0,62}\z')][string]$RunbookName,
        [Parameter(Mandatory)][ValidatePattern('\A[a-z0-9]{3,24}\z')][string]$StorageAccountName,
        [Parameter(Mandatory)][guid]$JobId,
        [Parameter(Mandatory)][ValidatePattern('\A[a-f0-9]{64}\z')][string]$FixtureSha256,
        [Parameter(Mandatory)][ValidatePattern('\A[a-f0-9]{64}\z')][string]$RunbookSha256,
        [Parameter(Mandatory)][string]$ReceiptPath,
        # Adapter contract: Request(method, uri, body, timeoutSeconds) returns
        # exactly {StatusCode:int; Body:object|null}; never return credentials.
        # Guard(timeoutSeconds) returns true after fresh identity/tenant/Enabled checks.
        # Preflight(timeoutSeconds) checks owned account/runbook hash, schedules,
        # control blobs and exact remote fixture identity, then returns true. All callbacks throw
        # on failed checks and honor the supplied remaining time budget.
        [Parameter(Mandatory)][scriptblock]$Request,
        [Parameter(Mandatory)][scriptblock]$Guard,
        [Parameter(Mandatory)][scriptblock]$Preflight,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600,
        [ValidateRange(1, 600)][int]$StopTimeoutSeconds = 120,
        [ValidateRange(1, 30)][int]$RequestTimeoutSeconds = 20,
        [ValidateRange(1, 30)][int]$PollSeconds = 5,
        [ValidateRange(1, 10)][int]$MaxReadErrors = 3,
        [switch]$ReconcileOnly,
        # Deterministic offline test seams; production defaults use a monotonic clock.
        [scriptblock]$Clock,
        [scriptblock]$Sleep
    )
    $ErrorActionPreference = 'Stop'
    foreach ($id in @($TenantId, $SubscriptionId, $JobId)) { if ($id -eq [guid]::Empty) { throw 'Nonempty target and job GUIDs are required.' } }
    if ($ResourceGroupName.EndsWith('.')) { throw 'Invalid resource group name.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $requestLimit = $RequestTimeoutSeconds
    if (-not $Clock) { $Clock = { $watch.Elapsed.TotalSeconds }.GetNewClosure() }
    if (-not $Sleep) { $Sleep = { param($seconds) Start-Sleep -Seconds $seconds } }
    $timeState = @{Last=-1.0}
    function Get-Time {
        $value = & $Clock
        if ($value -isnot [ValueType] -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or [double]$value -lt $timeState.Last) { throw 'Clock must be finite and monotonic.' }
        $timeState.Last = [double]$value
        return [double]$value
    }
    function Get-Budget([double]$Deadline) {
        $remaining = $Deadline - (Get-Time)
        if ($remaining -le 0) { throw [TimeoutException]::new('Operation deadline elapsed.') }
        return [int][math]::Max(1, [math]::Min($requestLimit, [math]::Ceiling($remaining)))
    }
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Automation/automationAccounts/$AutomationAccountName/jobs/$JobId"
    $uri = "https://management.azure.com${resourceId}?api-version=2024-10-23"
    $stopUri = "https://management.azure.com${resourceId}/stop?api-version=2024-10-23"
    $parameters = [ordered]@{StorageAccountName=$StorageAccountName;UseExistingExportsOnly='true';IncludeAdvancedHunting='false';UseDirectMergeDeviceLookup='false';DashboardDeliveryMode='SelfContained';Export='BlobStorage'}
    $payload = [ordered]@{properties=[ordered]@{runbook=[ordered]@{name=$RunbookName};parameters=$parameters}}
    $policy = [ordered]@{executionTimeoutSeconds=$TimeoutSeconds;stopTimeoutSeconds=$StopTimeoutSeconds;requestTimeoutSeconds=$RequestTimeoutSeconds;pollSeconds=$PollSeconds;maxReadErrors=$MaxReadErrors}
    $binding = [ordered]@{tenantId=$TenantId.ToString();subscriptionId=$SubscriptionId.ToString();jobResourceId=$resourceId;runbook=$RunbookName;storage=$StorageAccountName;fixtureSha256=$FixtureSha256;runbookSha256=$RunbookSha256;payload=$payload;policy=$policy}
    $bindingText = $binding | ConvertTo-Json -Depth 10 -Compress
    $bindingHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($bindingText))).ToLowerInvariant()
    $receiptFullPath = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Get-Item -LiteralPath (Split-Path -Path $receiptFullPath -Parent)
    if (-not $parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Receipt requires an existing ordinary parent directory.' }
    # OS file sharing is the lease. A leftover lease filename is not proof of a
    # running operation; a new process can acquire it after the old handle closes.
    $lease = [IO.File]::Open($receiptFullPath + '.lease', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if ($ReconcileOnly) {
            $oldFile = Get-Item -LiteralPath $receiptFullPath
            if ($oldFile.Length -gt 1MB -or ($oldFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid existing receipt.' }
            $receipt = Get-Content -LiteralPath $receiptFullPath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            if ($receipt.schemaVersion -ne 2 -or $receipt.bindingSha256 -cne $bindingHash -or ($receipt.binding | ConvertTo-Json -Depth 10 -Compress) -cne $bindingText) { throw 'Receipt does not match the approved operation.' }
        } else {
            $startedAt = [DateTimeOffset]::UtcNow
            $receipt = [ordered]@{schemaVersion=2;binding=$binding;bindingSha256=$bindingHash;createdAtUtc=$startedAt.ToString('o');executionDeadlineUtc=$startedAt.AddSeconds($TimeoutSeconds).ToString('o');submissionPossible=$false;submissionAttempted=$false;stopAttempted=$false;outcome='intent-recorded';terminalStatus=$null;quiescenceConfirmed=$false;cleanupAllowed=$false;evidenceWriteFailed=$false;eventsOmitted=0;events=@()}
            $intentStream = [IO.File]::Open($receiptFullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 20))
                $intentStream.Write($bytes, 0, $bytes.Length); $intentStream.Flush($true)
            } finally { $intentStream.Dispose() }
        }
        $receipt.quiescenceConfirmed = $false
        $receipt.terminalStatus = $null
        $receipt.outcome = 'intent-recorded'
        function Save-Event([string]$Code, [switch]$Required) {
            # Store only fixed codes/statuses, never raw exception/provider bodies.
            try {
                $history = @($receipt.events)
                $omitted = [math]::Max(0, $history.Count - 1999)
                if ($omitted -gt 0) { $history = @($history | Select-Object -Skip $omitted) }
                $receipt.eventsOmitted += $omitted
                $receipt.events = $history + @([ordered]@{atUtc=[datetime]::UtcNow.ToString('o');code=$Code})
                $receipt.cleanupAllowed = $false
                $stage = $receiptFullPath + '.stage-' + [guid]::NewGuid().ToString('N')
                $stageStream = [IO.File]::Open($stage, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 20))
                    $stageStream.Write($bytes, 0, $bytes.Length); $stageStream.Flush($true)
                } finally { $stageStream.Dispose() }
                [IO.File]::Move($stage, $receiptFullPath, $true)
            } catch {
                $receipt.evidenceWriteFailed = $true
                if ($Required) { throw 'Required receipt update failed; no submission permitted.' }
            }
        }
        function Confirm-Check([scriptblock]$Check, [double]$Deadline) {
            $checked = & $Check (Get-Budget $Deadline)
            if ($checked -isnot [bool] -or -not $checked) { throw 'Required guard/preflight did not explicitly pass.' }
        }
        function Read-Job([double]$Deadline) {
            $response = & $Request 'GET' $uri $null (Get-Budget $Deadline)
            if ($null -eq $response -or $response.StatusCode -isnot [int]) { throw 'Invalid transport response.' }
            if ($response.StatusCode -ne 200) { throw 'Job read did not return 200.' }
            try {
            $body = $response.Body
            if ($body -isnot [Collections.IDictionary] -or $body.id -isnot [string] -or $body.id -ine $resourceId -or
                $body.name -isnot [string] -or $body.name -ine $JobId.ToString() -or
                $body.properties.runbook.name -isnot [string] -or $body.properties.runbook.name -cne $RunbookName) {
                throw [IO.InvalidDataException]::new('Job identity mismatch.')
            }
            $readParameters = $body.properties.parameters
            foreach ($key in $parameters.Keys) {
                if ($readParameters[$key] -isnot [string] -or $readParameters[$key] -cne $parameters[$key]) { throw [IO.InvalidDataException]::new('Job parameters mismatch.') }
            }
            if (@($readParameters.Keys).Count -ne $parameters.Count -or $body.properties.status -isnot [string]) { throw [IO.InvalidDataException]::new('Job parameter shape or status mismatch.') }
            if ($body.properties.status -cnotin @('New','Activating','Queued','Starting','Running','Completed','Failed','Stopped','Blocked','Suspended','Disconnected','Suspending','Stopping','Resuming','Removing')) { return 'Unknown' }
            return $body.properties.status
            } catch { throw [IO.InvalidDataException]::new('Job binding response is invalid.') }
        }
        $originalStart = [DateTimeOffset]::Parse($receipt.createdAtUtc, [Globalization.CultureInfo]::InvariantCulture)
        $originalDeadline = [DateTimeOffset]::Parse($receipt.executionDeadlineUtc, [Globalization.CultureInfo]::InvariantCulture)
        if (($originalDeadline - $originalStart).TotalSeconds -ne $TimeoutSeconds) { throw 'Receipt execution deadline does not match its policy.' }
        # Persisted UTC bounds recovery across processes; use a monotonic clock
        # for the remaining portion during this invocation, never a fresh window.
        $remainingExecution = [math]::Max(0, [math]::Min($TimeoutSeconds, ($originalDeadline - [DateTimeOffset]::UtcNow).TotalSeconds))
        $deadline = (Get-Time) + $remainingExecution
        $bindingViolation = $false
        try {
            Confirm-Check $Guard $deadline
            if (-not $ReconcileOnly) {
                Confirm-Check $Preflight $deadline
                $existing = & $Request 'GET' $uri $null (Get-Budget $deadline)
                if ($null -eq $existing -or $existing.StatusCode -isnot [int] -or $existing.StatusCode -ne 404) { throw 'New job ID is not confirmed absent.' }
                Confirm-Check $Preflight $deadline
                Confirm-Check $Guard $deadline
                # Must persist possible submission before PUT, not after receiving it.
                $receipt.submissionPossible = $true
                $receipt.submissionAttempted = $true
                try { Save-Event 'submission-possible' -Required }
                catch {
                    $receipt.submissionPossible = $false
                    $receipt.submissionAttempted = $false
                    throw
                }
                try {
                    $submitted = & $Request 'PUT' $uri $payload (Get-Budget $deadline)
                    if ($null -eq $submitted -or $submitted.StatusCode -isnot [int] -or $submitted.StatusCode -ne 201) { throw 'Submission outcome uncertain.' }
                    Save-Event 'submission-201'
                } catch { Save-Event 'submission-uncertain' }
            } else { Save-Event 'same-job-reconciliation-started' }
            $errors = 0
            for ($poll = 0; $poll -lt 750; $poll++) {
                if ((Get-Time) -ge $deadline) { $receipt.outcome = 'execution-timeout'; break }
                try {
                    $status = Read-Job $deadline
                    $lateRead = (Get-Time) -ge $deadline
                    Save-Event ('job-' + $status)
                    if ($status -in @('Completed','Failed','Stopped')) {
                        $receipt.terminalStatus = $status; $receipt.quiescenceConfirmed = $true
                        $receipt.outcome = if ($lateRead) {'execution-timeout'} elseif ($status -ceq 'Completed') {'execution-completed'} else {'execution-failed'}
                        break
                    }
                    if ($status -in @('Suspended','Suspending','Blocked','Disconnected')) { $receipt.outcome='execution-not-progressing'; break }
                    if ($lateRead) { $receipt.outcome='execution-timeout'; break }
                    if ($status -notin @('New','Activating','Queued','Starting','Running','Resuming','Stopping','Removing')) { $receipt.outcome='unknown-status'; break }
                } catch [IO.InvalidDataException] {
                    $bindingViolation = $true; $receipt.outcome='binding-violation'; break
                } catch {
                    $errors++; Save-Event 'read-error'
                    if ($errors -ge $MaxReadErrors) { $receipt.outcome='read-budget-exhausted'; break }
                }
                & $Sleep ([math]::Max(0, [math]::Min($PollSeconds, $deadline - (Get-Time)))) | Out-Null
            }
            if (-not $receipt.quiescenceConfirmed -and $receipt.outcome -eq 'intent-recorded') { $receipt.outcome='poll-budget-exhausted' }
        } catch [TimeoutException] {
            $receipt.outcome = 'execution-timeout'
            Save-Event 'execution-deadline-elapsed'
        } catch {
            $receipt.outcome = 'operation-failed'
            Save-Event 'operation-error'
        }
        # ReconcileOnly never submits a job, but may stop the exact possibly
        # submitted job described by the saved intent after its observation bound.
        if ($receipt.submissionPossible -and -not $receipt.quiescenceConfirmed -and -not $bindingViolation) {
            $stopDeadline = (Get-Time) + $StopTimeoutSeconds
            try {
                Confirm-Check $Guard $stopDeadline
                if ($ReconcileOnly) {
                    # An expired original execution window must not prevent a
                    # fresh terminal check before attempting another stop.
                    try {
                        $status = Read-Job $stopDeadline
                        if ($status -in @('Completed','Failed','Stopped')) {
                            $receipt.terminalStatus=$status; $receipt.quiescenceConfirmed=$true
                        }
                    } catch [IO.InvalidDataException] { $bindingViolation=$true; Save-Event 'reconciliation-binding-violation' }
                    catch { Save-Event 'reconciliation-read-error' }
                }
                if (-not $receipt.quiescenceConfirmed -and -not $bindingViolation) {
                if ($ReconcileOnly) { Confirm-Check $Guard $stopDeadline }
                $receipt.stopAttempted = $true
                Save-Event 'stop-possible'
                try {
                    $stop = & $Request 'POST' $stopUri $null (Get-Budget $stopDeadline)
                    if ($null -eq $stop -or $stop.StatusCode -isnot [int] -or $stop.StatusCode -ne 200) { throw 'Stop outcome uncertain.' }
                    Save-Event 'stop-200'
                } catch { Save-Event 'stop-uncertain' }
                for ($poll = 0; $poll -lt 150; $poll++) {
                    if ((Get-Time) -ge $stopDeadline) { break }
                    try {
                        $status = Read-Job $stopDeadline
                        Save-Event ('stop-read-' + $status)
                        if ($status -in @('Completed','Failed','Stopped')) {
                            $receipt.terminalStatus=$status; $receipt.quiescenceConfirmed=$true; break
                        }
                    } catch [IO.InvalidDataException] { Save-Event 'stop-binding-violation'; break }
                    catch { Save-Event 'stop-read-error' }
                    & $Sleep ([math]::Max(0, [math]::Min($PollSeconds, $stopDeadline - (Get-Time)))) | Out-Null
                }
                }
            } catch { Save-Event 'stop-guard-or-operation-error' }
        }
        Save-Event 'observation-finished'
        [pscustomobject]@{
            outcome=$receipt.outcome;jobResourceId=$resourceId;receiptPath=$receiptFullPath
            submissionAttempted=$receipt.submissionAttempted;stopAttempted=$receipt.stopAttempted
            terminalStatus=$receipt.terminalStatus;quiescenceConfirmed=$receipt.quiescenceConfirmed
            cleanupAllowed=$false;requiresReconciliation=($receipt.submissionPossible -and -not $receipt.quiescenceConfirmed)
            evidenceWriteFailed=$receipt.evidenceWriteFailed
            eventsOmitted=$receipt.eventsOmitted
            limitation='Execution lifecycle only; no report acceptance, cleanup or live adapter is supplied.'
        }
    } finally { $lease.Dispose() }
}

Export-ModuleMember -Function Invoke-ValidationJobLifecycle
