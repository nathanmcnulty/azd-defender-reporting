# Upstream integration

This wrapper does not carry a copy of `defender-reporting`. Instead it resolves the upstream source at execution time.

## Resolution order

`Resolve-UpstreamRepo.ps1` uses:

1. `DEFENDER_REPORTING_PATH` when you already have a local checkout
2. a local cache under `.local\upstream\defender-reporting`
3. `DEFENDER_REPORTING_REPO` + `DEFENDER_REPORTING_REF` to hydrate or refresh that cache

## Defaults

If not set, the wrapper defaults to:

- `DEFENDER_REPORTING_REPO=https://github.com/nathanmcnulty/defender-reporting.git`
- `DEFENDER_REPORTING_REF=main`

## Why this wrapper uses a pinned-source model

- It keeps this repo thin.
- It avoids submodule churn while upstream is actively changing.
- It gives local development a clean override path.
- It makes later CI adoption straightforward because the wrapper can pin a specific ref.

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
- `azure\Upload-Templates.ps1`

`Publish-AutomationRunbook.ps1` resolves the upstream repo, invokes the upstream runbook build, uploads template assets through the upstream template uploader, and then publishes the generated runbook into the provisioned Automation Account runtime environment.

`Publish-HostedSurface.ps1` reuses the same template-upload contract and then validates that the provisioned Container App host is reachable for hosted dashboard delivery.
