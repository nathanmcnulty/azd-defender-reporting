# Supervised synthetic validation adapter

`Invoke-SyntheticAutomationValidation.ps1` defaults to an offline plan. Constructing
the adapter or planning does not authenticate or call Azure. `-Execute` is only for
a separately approved exact target and workload. It supplies the reviewed lifecycle
core with live callbacks; it does not provision, publish, upload, create identities,
grant roles, validate reports, delete blobs/resources or change scheduling.

Use a private JSON context with exactly these fields:

- TenantId, SubscriptionId and a client-selected JobId (nonempty GUID strings).
- ResourceGroupName, AutomationAccountName, RunbookName and StorageAccountName.
- AutomationPrincipalId and ExpectedUserName, from the approved identity readback.
- RunbookSha256, the exact published UTF-8 runbook bytes expected from the reviewed
  maintained build/publication path; no approximate source-to-deployment inference.
- FixtureSha256, the reviewed whole-fixture identity from Test-SyntheticExportFixture.
- RuntimeContractSha256, the byte digest returned by Get-AutomationRuntimeContract
  for the reviewed contracts/automation-runtime.json in this checkout.
- Artifacts and Templates, arrays of `{name, bytes, sha256}`. The inputs must already
  have passed the offline GZip/NDJSON/count/content gate. Template entries must come
  from the locked release's maintained publisher manifest, including its nested
  dashboard JavaScript modules. Do not hand-author a different template set.

GUIDs, names, flat input families, safe relative template paths, sizes, digests,
duplicate names and aggregate bounds are checked before authentication. Fixture
identity is recomputed from every selected filename/byte size/hash. Retain the exact
wrapper commit, dependency stack, source/lock/package identities and this context
alongside the action approval in private evidence. Do not publish it.

```powershell
./scripts/Invoke-SyntheticAutomationValidation.ps1 `
    -ContextPath <private-approved-context.json> `
    -ReceiptPath <new-private-job-receipt.json>
```

The resulting plan names the exact job, expected operator, runbook and fixture
identities, execution/stop bounds and permitted HTTP operations. Use the same
reviewed parameters with `-Execute` only after approval. ReconcileOnly suppresses
submission but may stop that same job, so its execution also requires approval.
The preserved lifecycle receipt binds all timeout/poll/read-error policy values.

`PreflightTimeoutSeconds` defaults to 120 (maximum 300), independently of the
1–30 second `RequestTimeoutSeconds`. The larger budget covers the complete
read-only preflight child, including startup, authentication and all artifact
checks. Artifact and runtime HTTP reads remain capped by the request limit and
the remaining preflight budget. The maintained target guard's subscription read
retains its own 30-second HTTP limit; the enclosing child still bounds the whole
callback. Guard and job-request children retain the request limit.
Both preflight passes still count against the original execution deadline;
increasing their allowance does not extend that deadline or reserve runtime for
the job. Measure the complete sequence before approving execution bounds.
Use `-PreflightTimeoutSeconds 0` only when reconciling a legacy receipt whose
policy omitted a separate preflight allowance. Never change a saved policy to
retry a failed or expired intent.

## Boundaries enforced by the adapter

Each callback runs in a fresh noninteractive PowerShell child without profiles or
visible windows. A total-operation deadline includes Azure CLI/token acquisition,
the maintained publisher guard and HTTP. It kills the process tree at timeout and
allows at most two additional seconds to confirm local exit. A killed/failed PUT
remains an uncertain submission: the lifecycle reconciles the same job ID.
Private stdin contains only approved context/payload data; no tokens are passed on
the command line, returned to the parent or written to receipts. Output/error pipes
are bounded, errors are fixed messages and JSON protocol duplicates are rejected.
JSON budgets and HTTP statuses accept only bounded integer values and are
normalized after deserialization; strings, fractional numbers and Booleans are
rejected rather than coerced.

The worker reuses Common-AzurePublish/Publish-TargetGuard for public-cloud tenant,
subscription, token metadata and fresh Enabled checks. It additionally checks the
exact signed-in user. HTTP is bounded, redirects/cookies are disabled and no retry
is implemented. Its mutation allowlist is one exact Jobs PUT and that job's POST
stop; GET uses the same job URI. Payloads have exactly the six safe synthetic
parameters. Even invalid worker protocol requests are rejected before authentication.

Remote preflight reads the exact account/principal and storage endpoint, complete
empty schedule/link inventories and a complete job list without unresolved jobs.
It checks Published PowerShell runbook metadata and exact content bytes, confirms
the overriding control blob absent, and compares complete exports/templates blob
inventories plus every selected blob's actual byte size and SHA256. Listings with
continuations, unknown blobs, prefixes, malformed XML/DTD or ambiguous JSON fail
closed. It uses only the bound ARM and storage token destinations.
Preflight also checks the runbook's runtime binding, PowerShell version, empty
default-package configuration and a complete inventory containing only the locked
Az.Accounts version in Succeeded state. A changed local contract digest fails before
authentication. These checks establish runtime metadata, not measured remote bytes.

The [runbook content API](https://learn.microsoft.com/en-us/rest/api/automation/runbook/get-content?view=rest-automation-2024-10-23)
is requested as text/plain for byte identity. Blob inventories follow the
[List Blobs API](https://learn.microsoft.com/en-us/rest/api/storageservices/list-blobs),
including mandatory empty NextMarker for complete bounded enumeration.

## What remains separate

Readback does not lock the account or storage: the approved cell must have one
mutation owner. This adapter does not establish ownership from tags or prevent an unrelated operator
from changing the environment concurrently. Those remain explicit provisioning,
provenance and isolation gates. Do not target retained or unknown-owner resources
as disposable fixtures.

Offline tests cover policy/preflight using fake responses, the HTTP response path
with an in-memory handler and actual child-process timeout/tree termination. They
also exercise 404/201/200 child JSON responses through the single-submit lifecycle
and prove valid serialized budgets reach a fake CLI guard while invalid ones do not.
They do not constitute native Azure acceptance or a real network-service timeout probe.
Before calling a solution aligned, qualify the approved native procedure, structured
current-run report content/counts, schedules, identities, costs and cleanup. No
cleanup is supplied or authorized here; cleanupAllowed remains false.
