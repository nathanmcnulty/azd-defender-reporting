# Upstream integration

This wrapper does not carry a copy of `defender-reporting`. Instead it resolves the upstream source at execution time.

## Resolution order

`Resolve-UpstreamRepo.ps1` uses:

1. `DEFENDER_REPORTING_PATH` when you already have a local checkout
2. explicit `DEFENDER_REPORTING_REPO` + `DEFENDER_REPORTING_REF` overrides
3. the tested repository, release, and full commit SHA in `contracts\upstream-lock.json`
4. a local cache under `.local\upstream\defender-reporting`

## Defaults

If not set, the wrapper defaults to:

- `DEFENDER_REPORTING_REPO=https://github.com/nathanmcnulty/defender-reporting.git`
- `DEFENDER_REPORTING_REF=v2026.07.13`
- expected commit `28c68b4ea5521f834884a8f7aad9cfb38f1588b8`

The resolver verifies the full commit when the default repository and ref are used. Explicit repository/ref overrides and local paths are supported for development, but are reported as not matching the compatibility lock when they resolve elsewhere.

## Why this wrapper uses a pinned-source model

- It keeps this repo thin.
- It avoids submodule churn while upstream is actively changing.
- It gives local development a clean override path.
- It makes CI deterministic while retaining explicit development overrides.

## Updating the lock

`.github\workflows\update-upstream.yml` runs weekly and on demand. It resolves the latest upstream release, runs the complete wrapper compatibility suite against that checkout, updates the lock only after success, and opens a pull request. The same process can be run locally:

```powershell
.\scripts\Update-UpstreamLock.ps1 -CandidateRef <release>       # test only
.\scripts\Update-UpstreamLock.ps1 -CandidateRef <release> -UpdateLock
```

## Function App package contract

The wrapper now expects the upstream repo to provide:

- `build\Build-FunctionAppPackage.ps1`
- a zip package output path
- a sibling manifest containing at least:
  - `packagePath`
  - `packageSha256`
  - `packageSizeBytes`
  - `functionAppEntryPointFingerprint`
  - `sharedHelpersFingerprint`
  - staged `Az.Accounts` metadata

`Publish-FunctionAppPackage.ps1` resolves the upstream repo, invokes that build script, reads the manifest, validates the package hash and size, stages the build output as `released-package.zip`, uploads it to the provisioned Flex deployment container, and invokes the Function App `onedeploy` extension with a short-lived SAS URL.

If the upstream script or manifest contract is missing, the wrapper fails with a clear contract error instead of guessing at internal repo structure.

## Automation runbook and template contracts

The wrapper also expects the upstream repo to provide:

- `build\azure\Build-Runbook.ps1`
- generated runbook output at `azure\Invoke-DashboardPipeline.ps1`
- a template publish surface, preferably `build\Publish-DashboardTemplates.ps1`
- `build\Publish-DashboardTemplates.ps1` with `-MetadataPath`

`Publish-AutomationRunbook.ps1` resolves the upstream repo, invokes the upstream runbook build, verifies its exact parameter set and shared-helper fingerprint, writes a wrapper-owned manifest under `.local\artifacts\automation-runbook`, uploads template assets, and publishes the generated runbook into the provisioned Automation Account runtime environment.

`Publish-TemplateAssets.ps1` requires the documented build-layer publisher and validates its metadata schema, safe paths, file hashes, file count, and aggregate size before accepting publication.

`Publish-HostedSurface.ps1` reuses the same template-publish contract, configures the hosted Container App Easy Auth path by default unless the operator explicitly opts out, and then validates that the provisioned Container App host is reachable for hosted dashboard delivery.

`contracts\hosted-assets.json` is consumed by both PowerShell and Bicep. Validation compares its paths exactly with the upstream `hostedAssets` test contract. Container synchronization fails when a required asset is unavailable while optional PDF assets remain best effort.
