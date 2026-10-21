# Synthetic Automation job lifecycle

`scripts/AutomationJobLifecycle.psm1` supplies a bounded state machine for one
explicit job ID. It has no default Azure transport and is not a live validation
entrypoint. Importing it performs no Azure action. Its callbacks allow offline
failure qualification before wiring the maintained publisher target guards into
a separately approved live procedure.

The separate [supervised adapter](automation-validation-adapter.md) now provides
those callbacks and an offline-default planning entrypoint. It still requires
independent integration review and scoped action approval before live execution.

The protocol uses the Automation 2024-10-23 Jobs API:
[create](https://learn.microsoft.com/en-us/rest/api/automation/job/create?view=rest-automation-2024-10-23),
[read](https://learn.microsoft.com/en-us/rest/api/automation/job/get?view=rest-automation-2024-10-23),
and [stop](https://learn.microsoft.com/en-us/rest/api/automation/job/stop?view=rest-automation-2024-10-23).
One client-selected GUID identifies the resource; a new receipt permits at most
one PUT. Lost responses and absent reads never cause another PUT. A 201 is not
execution success: reads must match the job ID/name, runbook and six safe parameters.

## Callback contract and remaining integration

Callbacks are trusted procedure code, not serialized data or user script text:

- `Request(method, uri, body, timeoutSeconds)` issues exactly one bounded request,
  without redirects/retries, and returns one dictionary containing integer
  `StatusCode` and dictionary `Body` (or null for absence/empty replies). The
  adapter must bound response size, reject ambiguous JSON and sanitize errors.
- `Guard(timeoutSeconds)` verifies the exact authenticated identity, tenant,
  explicit subscription and fresh Enabled state, then returns Boolean true.
  False/missing output or an exception fails closed. Reuse the maintained guard;
  do not rely on ambient CLI defaults. It runs before observation and immediately
  before PUT and POST.
- `Preflight(timeoutSeconds)` returns Boolean true after checking the owned
  account, exact published runbook content/hash, no schedules/links, no control
  blob overriding the parameters, and the exact approved remote fixture identity.
  It runs twice before submission. This readback is not a remote lock: serialize
  other account mutations throughout the cell.

Every callback must honor its remaining budget. Defaults use a monotonic
stopwatch, an absolute execution deadline and a separate stop/readback deadline.
Request budgets round up to whole seconds (at most one second of granularity).
Poll counts remain bounded even if a faulty test clock stalls. Clock/sleep
overrides are deterministic offline test seams. A future live adapter must prove
its own timeout and HTTP behavior; module tests do not qualify that adapter.

The fixed string parameters are the approved StorageAccountName,
UseExistingExportsOnly=true, IncludeAdvancedHunting=false,
UseDirectMergeDeviceLookup=false, DashboardDeliveryMode=SelfContained and
Export=BlobStorage. There are no extra parameters or runOn override. Flags do not
replace control-blob and input preflight.

## Receipts and failure outcomes

Supply an existing private receipt directory, fixture and published-runbook
SHA256 identities, and a new receipt filename. The core refuses an existing
receipt for new submission. It flushes the exact target/payload/job intent and an
atomic possible-submission marker before PUT. Failure to persist that marker
prevents PUT. Updates contain fixed event codes and validated statuses, never raw
provider errors or tokens.

The schema-v2 binding includes all timeout/poll/read-error policy values. The
original UTC execution deadline is preserved across process recovery, and each
invocation uses a monotonic clock for its remaining portion. Resuming cannot
grant another execution window or change the approved policy. Cancellation gets
a separately bounded recovery attempt; an expired job first gets fresh readback
to avoid stopping an already-terminal job. Older prototype receipts are rejected.
Events retain a bounded newest-2,000 tail with an explicit omitted-event counter;
event saturation must not throw past cancellation.

`-ReconcileOnly` compares the same saved binding and suppresses submission. It
can stop the exact saved job after its observation bound, so it is not a read-only
switch and requires scoped approval for live use. Prior terminal observations
are reset; the new run needs fresh readback. After a process crash, preserve the
receipt and reconcile the same ID. Do not create a replacement job. The lease is
an exclusive OS file handle; a leftover lease filename does not prove a process
is running.

Only Completed, Failed and Stopped confirm terminal quiescence. Failed/Stopped
are unsuccessful execution. Suspended/Blocked/Disconnected and unknown states
trigger cancellation, as do absolute deadlines despite continuous Running reads.
A late Completed read confirms quiescence but remains an execution-timeout.

Cancellation uses a fresh guard, one exact-job stop attempt and bounded terminal
polling. Stop acknowledgement is not terminal confirmation. A lost stop response
still needs readback. Failed guard/readback or contradictory job bindings leave
reconciliation required; contradictory bindings prevent stopping an unverified
job. Failures never permit permission expansion or cleanup. Receipt-write failure
after submission does not skip cancellation: the result marks the evidence
failure for the caller to preserve separately.

`cleanupAllowed` is always false. Even execution-completed is only a lifecycle
result. There is no cleanup or report freshness/semantic validation here. Live
acceptance still needs a reviewed adapter/preflight, source/dependency identity,
meaningful output checks, a costed action approval and separately qualified owned
cleanup. The archived replacement/container-restore harness is not that adapter;
retained or unknown-owner environments are not disposable cells.
