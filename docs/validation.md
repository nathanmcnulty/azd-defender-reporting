# Validation

Use PowerShell 7.6 or later. To run the bundled-release tests, install and import
Pester 6.2.0 explicitly:

```powershell
Install-Module Pester -RequiredVersion 6.2.0 -Scope CurrentUser
Import-Module Pester -RequiredVersion 6.2.0
Invoke-Pester ./tests
```

Run the wrapper-owned validation entrypoint:

```powershell
.\scripts\Validate-Repository.ps1
```

It currently validates:

1. deployment-mode normalization and default resolution
2. PowerShell syntax for all scripts under `scripts/`
3. Bicep compilation through `az bicep build --file .\infra\main.bicep`
4. optional upstream Function App package build-only validation
5. optional upstream Automation runbook build-only validation
6. upstream dashboard template publisher contract validation
7. exact hosted dashboard asset-set validation

Run every locked-upstream contract in one command:

```powershell
.\scripts\Validate-Repository.ps1 -ValidateAllUpstreamContracts
```

This default path validates the committed source archive and rebuilds from it without fetching upstream source. `contracts/upstream-package.json` pins its SHA-256 and size to the immutable commit in `contracts/upstream-lock.json`. The supported Function App publish path instead verifies and deploys the prebuilt package pinned in `contracts/released-function-app.json`, so build-host module selection cannot change deployed bytes. A local checkout is only needed for an explicit development override.

The wrapper publish entrypoint also supports a no-change planning pass:

```powershell
.\scripts\Publish-Deployment.ps1 -ResourceGroupName <rg> -PlanOnly
.\scripts\Deploy.ps1 -PlanOnly
```

You can also validate the real upstream Function App package integration when you have a local `defender-reporting` checkout:

```powershell
.\scripts\Validate-Repository.ps1 `
    -ValidateFunctionAppPackage `
    -UpstreamRepositoryPath C:\path\to\defender-reporting
```

You can validate the upstream Automation runbook build contract the same way:

```powershell
.\scripts\Validate-Repository.ps1 `
    -ValidateAutomationRunbook `
    -UpstreamRepositoryPath C:\path\to\defender-reporting
```

You can request both build-only validations in one pass:

```powershell
.\scripts\Validate-Repository.ps1 `
    -ValidateFunctionAppPackage `
    -ValidateAutomationRunbook `
    -UpstreamRepositoryPath C:\path\to\defender-reporting
```

## Continuous validation

`.github\workflows\validate.yml` runs the complete locked-upstream suite on pull requests, pushes to `main`, weekly schedules, and manual dispatch. Configure branch protection so **Validate wrapper contracts / validate** is required before merging.

`.github\workflows\update-upstream.yml` tests the latest upstream release before changing the lock or opening a pull request. A new release is never promoted solely because it exists.

## Live Azure smoke validation

After provisioning and publication, run:

```powershell
.\scripts\Test-LiveDeployment.ps1 -ResourceGroupName <rg>
.\scripts\Test-LiveDeployment.ps1 -ResourceGroupName <rg> -AccessToken <token>
```

The smoke test verifies a nonempty dashboard blob, every required hosted asset, Container App reachability, and expected unauthenticated challenge behavior. With a bearer token it additionally requires HTTP 200 and rejects the placeholder page.

`.github\workflows\live-smoke.yml` provides scheduled and manual OIDC-backed coverage. It is opt-in: set repository variable `AZURE_SMOKE_ENABLED=true`, configure `AZURE_LOCATION` and `AZURE_SMOKE_RESOURCE_GROUP`, and provide federated-identity secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID`. Use a dedicated disposable environment and least-privilege identity.

Local validation proves:

- `azure.yaml` hook inputs are normalized
- the wrapper scripts parse
- the Bicep matrix compiles
- the upstream Function App package contract still builds
- the upstream Automation runbook contract still builds
- template metadata and hosted assets remain compatible

Optional live publish validation can now exercise the full Flex Consumption publish path, the Automation publish path, and the hosted Container App surface once a real Azure environment exists and the signed-in operator has blob data access to the wrapper storage account.

Live validation is intentionally separate because it mutates Azure resources and requires credentials; ordinary pull-request validation remains deterministic and Azure-free.

## Manual-only Automation validation (issue #26)

For a separately approved, isolated `automation` / `none` / `selfcontained`
validation cell, pass `-ManualOnly` to `Deploy.ps1`, `Publish-Deployment.ps1`, or
`Publish-AutomationRunbook.ps1`. `auto` is accepted when it resolves to
`selfcontained`. This explicit switch is not persisted in the azd environment.
Omitting it preserves the production daily-schedule behavior.

The maintained publisher still builds, verifies and publishes the locked
runbook, its runtime, templates and variables. It creates no schedule, schedule
association or job, and does not disable or delete existing scheduling. Before
publication, it requires both the account's schedules and job-schedule links to
be empty; existing, malformed, failed or incomplete listings stop the operation.
Use a new dedicated account, not a shared account with unrelated schedules.
The check is a readback, not a lock against another operator changing the account.

`-BuildOnly` and fully specified `Publish-Deployment.ps1 -PlanOnly` remain offline.
Their output describes the requested mode; it does not establish Azure scheduling
state. `Deploy.ps1 -PlanOnly` still performs its existing guarded infrastructure
preview. Do not rerun normal publication without `-ManualOnly` during this cell:
normal publication intentionally enables the daily schedule.

After separate approval, manually start the published runbook through the
[Azure Automation ARM Jobs API](https://learn.microsoft.com/en-us/rest/api/automation/job/create?view=rest-automation-2024-10-23),
using the same explicit subscription/tenant and fresh Enabled-state guard before
each mutation. This supports Entra authentication without a Function host key,
Automation webhook, storage key or new credential. Bind the exact account,
runbook and job ID; reconcile an uncertain job submission rather than replaying it.
Keep any bounded job count, timeout/stop policy and cleanup in the approval packet.

A synthetic existing-export smoke must explicitly pass `UseExistingExportsOnly=true`,
`IncludeAdvancedHunting=false`, `UseDirectMergeDeviceLookup=false`,
`DashboardDeliveryMode=SelfContained` and `Export=BlobStorage`, with only approved
synthetic inputs in the isolated account. It exercises the native runtime,
managed-identity storage access and report output, not real Defender API access,
live data export, daily scheduling or the other deployment-matrix cells.
No deployment, job, role grant, data upload or cleanup is authorized by this
documentation or by passing offline tests.

## Automation runtime storage permissions

### Offline synthetic export input gate

Before requesting a live synthetic Automation cell, validate a tiny procedural
dataset produced by the locked upstream release. The upstream
`Generate-SyntheticLargeExports.ps1 -IncludeRawRows` creates canonical current and
history data; `New-SyntheticLegacyVulnSnapshotSet.ps1` materializes dated raw-export
blobs and `New-SyntheticUploadManifest.ps1 -Mode RawReplay` selects the uploads.
Use new output directories and preserve the locked archive. The locked legacy
snapshot helper has a scalar `.Count` failure when exactly one date is selected;
use two explicit dates and independently calculate the eligible rows on each date.
Do not rename an uncompressed sample or a canonical current file to imitate a raw
export. Copy the generated synthetic machine snapshot into the raw-export directory.
Omit enrichment inputs when qualifying the cell with Advanced Hunting disabled.

Run the wrapper's offline gate with independently established counts:

```powershell
./scripts/Test-SyntheticExportFixture.ps1 `
    -DatasetPath <fixture-directory> `
    -UploadManifestPath <raw-replay-upload-manifest.json> `
    -ExpectedDeviceCount <device-count> `
    -ExpectedVulnerabilityRows <total-input-rows-across-dated-files>
```

This accepts only genuine bounded GZip UTF-8 NDJSON machine/datetime-group export
inputs. It verifies the upstream manifest's paths, byte sizes and hashes, exact
input membership, object records, synthetic machine identities and vulnerability
references, and expected counts. It emits a sorted row-content digest. Retain that
digest with the reviewed fixture, then pass
`-ExpectedVulnerabilityContentSha256 <digest>` to detect changed content even when
someone regenerates the transport manifest. The vulnerability digest is a row
multiset and does not bind filenames or machine content. For the whole approved
input set, retain `fixtureSha256` and require `-ExpectedFixtureSha256 <digest>`;
this binds every selected filename, compressed byte size and SHA256, including
machine content and date/group distribution. The GZip decoder uses .NET framing
behavior and does not enforce a canonical single-member/no-trailing-bytes format;
retain the reviewed per-artifact hashes and whole-fixture identity for approval.
The only extra local file allowed is
the upstream `synthetic-legacy-manifest.json`; it is not uploaded by RawReplay.

Input-row counts include repeated observations across dates. They are not an
expected final dashboard count; use the locked upstream semantic/source projection
checks to determine report expectations. This gate performs no Azure operations
and does not qualify job lifecycle, freshness, output correctness or cleanup.
Before live execution, separately qualify exact-target submission/reconciliation,
absolute timeout with confirmed stopping, remote control-blob and schedule/input
preflight, semantic output checks and owned-fixture cleanup. No upload, job,
permission, publication, deployment or deletion is authorized by passing this gate.

The [synthetic job lifecycle core](automation-job-lifecycle.md) separately
qualifies single-ID submission/reconciliation and timeout/stop behavior using
bounded offline adapters. It has no live Azure transport or cleanup implementation.

New Automation deployments assign the runbook's managed identity **Storage Blob
Data Contributor** on the wrapper storage account, without the redundant Blob
Data Owner assignment. The locked runbook uses bearer-authenticated Blob
operations to list/read inputs and templates, write exports/status/cache/report
blobs, and delete or migrate its old artifacts. Those operations are covered by
[Blob Data Contributor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage#storage-blob-data-contributor).
The [operation-to-permission mapping](https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-azure-active-directory#permissions-for-calling-data-operations)
also covers the optional blob tier set during upload. The runbook does not set
filesystem ownership or ACLs, which are among the additional
capabilities supplied by Blob Data Owner. This does not alter Defender API
application permissions, dependency selection or native qualification gates.

The separate Function identity, optional deployer identity and their existing
role assignments are unchanged, as are default daily scheduling and manual-only
publication behavior. `tests/AutomationRbac.Tests.ps1` compiles the actual Bicep
module graph and checks the enabled role IDs, account scope, identity binding
and unchanged Function/deployer role sets. Bicep must be installed before tests;
the tests perform no login or deployment.

**Existing deployments require a separate migration decision.**
[Incremental ARM deployment](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deployment-modes)
does not remove a previously created Blob Data Owner assignment when the template
stops requesting it. Do not claim a redeployment revoked that role.
Any removal must be separately approved for the exact owned assignment, scope
and principal, after verifying Contributor access and unrelated/inherited grants.
This source change performs no live role removal or other permission mutation.
Prefer a new isolated account for the first approved native validation cell.

## Explicit operator publication target (issue #23)

All maintained publication entrypoints accept `-SubscriptionId` and `-TenantId`.
When omitted, they resolve `AZURE_SUBSCRIPTION_ID` and `AZURE_TENANT_ID` from the
process or selected azd environment. CLI defaults never establish approval and
are never changed. `Deploy.ps1` additionally requires the selected azd environment
to match both selectors before provisioning; publication-only execution can use
`-SkipProvision`. The read-only smoke entrypoint receives the same selectors.

The local operator guard adapts the subscription/tenant/Enabled checks reviewed
in azd-reference commit `59522c4` (PR #131). A scoped CLI account check and a newly
acquired, metadata-verified ARM token precede a fresh subscription GET. Only an
exact subscription ID, tenant ID and `Enabled` state pass. Every mutation gets
another fresh check, including cache hits, template files and OneDeploy retries.
Discovered compute/storage IDs must match the requested subscription, resource
group, type and name. Public-cloud storage endpoints must match the bound account.
Graph tokens are selected by tenant (CLI disallows combining tenant and subscription
selectors); ARM/storage tokens are selected by subscription and verify both fields.
Caches include resource, subscription and tenant. This operator-only adaptation does
not import the unrelated hosted runtime or require a network fetch from Reference.

The frozen upstream template publisher uses ambient authentication. The maintained
wrapper therefore reuses its offline template-state/manifest helpers but owns the
bound HTTP uploads. The upstream archive, release package, compatibility hashes and
manifest shape are unchanged; no upstream publishing/authentication helper is called.
Metadata is written only after all uploads succeed. Publication errors fail closed
without fallback login or automatic replay of template uploads.

`-BuildOnly` remains authentication-free. Fully specified non-hosted
`Publish-Deployment.ps1 -PlanOnly` is offline; plans requiring discovery or hosted
auth inspection require target validation. Hosted planning never uploads templates.
`Validate-Repository.ps1 -ValidateAllUpstreamContracts` remains offline (Bicep and
local Az.Accounts build input are required). Automatic deployer identity discovery
is confined to preprovision and uses the verified target; ordinary validation does
not consult ambient identities.

`tests/PublisherTarget.Tests.ps1` invokes actual maintained entrypoints using strict
native/HTTP tripwires. It covers malformed/missing selectors, cached Enabled versus
fresh Disabled, wrong/malformed/failed ARM reads, wrong token metadata, exact resource
bindings, state changes after the first write, cross-target cache isolation,
non-default valid targets, Function/Automation orchestration, hosted auth and offline
paths. Tests do not authenticate or perform live writes. Passing source tests or CI
is not publisher/Azure qualification; issue #20 and REPORT-002 retain the approved
native deployment, workload, delivery and cleanup gates.

Source validation for this change: PowerShell 7.6.6 / .NET 10.0.12 / Pester 6.2.0:
109 tests passed, zero failures/skips/inconclusive/not-run outcomes. Full
`Validate-Repository.ps1 -ValidateAllUpstreamContracts` passed, including Bicep
0.42.1 compilation, Function rebuild, Automation generation, template contract and
hosted assets. The local Function rebuild used Az.Accounts 5.5.0 extracted from the
already SHA-256-locked release package, with no authentication or module fetch.
Canonical backlog schema/generated-view checks and `git diff --check` passed.
These are offline source checks only; no live publisher or Azure outcome is claimed.
