# Upstream integration

This wrapper includes a reviewed source archive for the locked `defender-reporting` release. The supported default publish path verifies and extracts that archive locally before building; a fresh checkout does not need the upstream source service at deployment time.

## Resolution order

`Resolve-UpstreamRepo.ps1` uses:

1. `DEFENDER_REPORTING_PATH` when you already have a local checkout
2. the bundled archive in `vendor\defender-reporting-source.zip` when the repository/ref match the tested lock
3. explicit `DEFENDER_REPORTING_REPO` + `DEFENDER_REPORTING_REF` overrides for development

The bundle lock in `contracts\upstream-package.json` binds the archive's exact SHA-256 and size to the upstream commit in `contracts\upstream-lock.json`. The resolver verifies the archive before extraction into `.local\bundled`. `contracts\released-function-app.json` separately binds the prebuilt Function App package to that same commit, its exact SHA-256 and size, and the staged Az.Accounts version. A changed or missing archive or package stops publication. Explicit development overrides continue to use a local checkout or `.local\upstream\defender-reporting` Git cache and are reported separately from the tested bundle.

## Defaults

If not set, the wrapper defaults to:

- `DEFENDER_REPORTING_REPO=https://github.com/nathanmcnulty/defender-reporting.git`
- `DEFENDER_REPORTING_REF=v2026.07.13`
- expected commit `28c68b4ea5521f834884a8f7aad9cfb38f1588b8`

The resolver verifies the full commit when the default repository and ref are used. Explicit repository/ref overrides and local paths are supported for development, but are reported as not matching the compatibility lock when they resolve elsewhere.

## Why this wrapper bundles a pinned release

- The supported publish path can build from a fresh checkout without fetching upstream source.
- The archive is generated from the reviewed immutable upstream Git commit and locked by SHA-256. The default Function App publish path deploys a verified package from that source rather than selecting whichever Az.Accounts module version is newest on the publishing host.
- It gives local development a clean override path.
- It makes CI and release validation use the same default source package.

## Updating the lock

`.github\workflows\update-upstream.yml` runs weekly and on demand. It resolves the latest upstream release, runs the complete wrapper compatibility suite against that checkout, archives the validated commit and Function App build, updates the locks and package files, and opens a pull request. The same process can be run locally:

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

For the locked default, `Publish-FunctionAppPackage.ps1` verifies the committed release package and stages it as `released-package.zip`, uploads it to the provisioned Flex deployment container, and invokes the Function App `onedeploy` extension with a short-lived SAS URL. `Validate-Repository.ps1 -ValidateAllUpstreamContracts` separately rebuilds from the bundled source as a compatibility check. Explicit development overrides continue to invoke the upstream build script and validate its manifest and package hash.

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
