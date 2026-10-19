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
