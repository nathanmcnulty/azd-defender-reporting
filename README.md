# azd-defender-reporting

Thin Azure Developer CLI wrapper for [`nathanmcnulty/defender-reporting`](https://github.com/nathanmcnulty/defender-reporting).

This repo is intentionally **not** a fork of the dashboard application. The upstream repo remains the source of truth for export, dashboard generation, and Azure package build logic. This wrapper owns:

- `azure.yaml` workflow orchestration
- `infra/` Bicep provisioning
- `scripts/` PowerShell validation, upstream resolution, and publish orchestration
- wrapper-specific docs and deployment contracts

## Current scope

The current wrapper is meant to be runnable for:

- `azd provision`
- local structural validation of the wrapper contract
- mode selection across Function App vs Automation Account and Container App vs no-web
- compute publish for both Function App and Automation Account
- hosted Container App validation against the storage-backed dashboard path

The **Function App publish** path is now wired to the upstream package contract:

- upstream script: `build\Build-FunctionAppPackage.ps1`
- default wrapper build output: `.local\artifacts\function-app-package\defender-reporting-function-app.zip`
- validation build output: `.local\validation\function-app-package\defender-reporting-function-app.zip`
- sibling manifest: `.manifest.json`

The wrapper resolves upstream source, invokes that script, validates the manifest contract, uploads required template assets, stages the package as `released-package.zip`, uploads it to the Flex deployment container, and invokes the Function App `onedeploy` extension. It still fails clearly when the upstream script or manifest contract is missing.

The **Automation Account publish** path is also wired to the upstream runbook contract:

- upstream script: `build\azure\Build-Runbook.ps1`
- generated runbook artifact: `azure\Invoke-DashboardPipeline.ps1`
- wrapper publish script: `scripts\Publish-AutomationRunbook.ps1`

The wrapper builds the upstream runbook, uploads template assets, creates or updates the PowerShell 7.4 runtime environment, publishes `Invoke-DashboardPipeline`, sets the required Automation variables, and maintains the daily schedule.

The **hosted web surface** is a blob-backed Container App:

- image default: `docker.io/library/caddy:alpine`
- wrapper publish scripts: `scripts\Publish-Deployment.ps1` (top-level) and `scripts\Publish-HostedSurface.ps1` (hosted-only)
- runtime behavior: managed identity reads the `dashboards` container and serves the latest hosted dashboard or a placeholder page
- default hosted publish behavior: configure Entra ID Easy Auth; use a security-group restriction when configured, otherwise allow any authenticated user in the tenant unless you explicitly opt out

## Deployment model

The wrapper currently models two orthogonal choices:

| Setting | Values | Default | Meaning |
| --- | --- | --- | --- |
| `COMPUTE_KIND` | `functionapp`, `automation` | `functionapp` | Which Azure compute resource is provisioned |
| `WEB_KIND` | `containerapp`, `none` | `containerapp` | Whether the hosted web surface is provisioned |
| `DASHBOARD_PACKAGE_MODE` | `auto`, `hosted`, `selfcontained`, `dual` | `auto` | Packaging mode; `auto` resolves from `WEB_KIND` |

`auto` resolves as:

- `WEB_KIND=containerapp` -> `hosted`
- `WEB_KIND=none` -> `selfcontained`

Future `WebApp` hosting can be added by introducing a new web module and script path without changing the compute contract.

## Upstream contract

The wrapper resolves upstream source from either:

1. `DEFENDER_REPORTING_PATH` for a local side-by-side checkout, or
2. `DEFENDER_REPORTING_REPO` + `DEFENDER_REPORTING_REF` for a pinned clone into local cache

See [docs/upstream-integration.md](docs/upstream-integration.md) for the exact behavior.

## Quick start

1. Authenticate Azure tooling.

   ```powershell
   azd auth login
   az login
   ```

2. Create or select an azd environment.

   ```powershell
   azd env new dev
   ```

3. Optional: override the defaults.

   ```powershell
   azd env set COMPUTE_KIND automation
   azd env set WEB_KIND none
   azd env set DEFENDER_REPORTING_REF main
   azd env set HOSTED_AUTH_SECURITY_GROUP "Dashboard Viewers"  # optional; omit for tenant-wide authenticated-user access
   ```

4. Run the local wrapper validation.

   ```powershell
   .\scripts\Validate-Repository.ps1
   ```

5. Provision infrastructure.

   ```powershell
   azd provision
   ```

6. Publish through the wrapper-owned orchestrator.

   ```powershell
   .\scripts\Publish-Deployment.ps1 -ResourceGroupName <rg>
   ```

   Hosted publish now defaults to the secured Easy Auth path. If `HOSTED_AUTH_SECURITY_GROUP` (or `-SecurityGroup`) is set, the wrapper restricts access to that Entra group. If it is omitted, the wrapper still configures Easy Auth but allows any authenticated user in the tenant. If you intentionally want to leave auth management to another process, pass `-SkipAuthSetup` or set `SKIP_HOSTED_AUTH_SETUP=true`. That opt-out skips wrapper auth management and preserves any existing Easy Auth configuration already on the Container App.

   You can still run the narrower entrypoints directly when needed:

   ```powershell
   .\scripts\Publish-FunctionAppPackage.ps1 -ResourceGroupName <rg> -FunctionAppName <func>
   .\scripts\Publish-AutomationRunbook.ps1 -ResourceGroupName <rg> -AutomationAccountName <account>
   .\scripts\Publish-HostedSurface.ps1 -ResourceGroupName <rg> -ContainerAppName <app> -SecurityGroup "Dashboard Viewers"
   .\scripts\Publish-HostedSurface.ps1 -ResourceGroupName <rg> -ContainerAppName <app>  # tenant-wide authenticated-user access
   ```

At this stage the wrapper provisions the Azure resource matrix, validates the local contracts, and can publish the upstream Function App, Automation Account, template assets, and hosted Container App surfaces when the upstream repo path or ref is available.

For publish operations, the signed-in operator needs blob **data-plane** access to the wrapper storage account. Template upload, Function App package upload, and SAS generation all use storage data-plane APIs. The wrapper accepts `DEPLOYER_PRINCIPAL_ID` and `DEPLOYER_PRINCIPAL_TYPE` and will auto-populate them during environment validation when Azure CLI can resolve the signed-in principal.

## Files added by this scaffold

- `azure.yaml` - azd workflow and hook registration
- `infra/` - Bicep modules for storage, monitoring, Function App, Automation Account, and Container App
- `scripts/` - validation, mode normalization, upstream resolution, and publish orchestration
- `docs/` - wrapper-specific behavior and operating notes

## Validation

Run the repo-owned validation entrypoint:

```powershell
.\scripts\Validate-Repository.ps1
```

It currently validates:

- deployment-mode normalization
- PowerShell script parsing
- Bicep compilation through `az bicep build`
- optional upstream Function App package build-only validation
- optional upstream Automation runbook build-only validation

The publish entrypoint also supports a non-mutating plan mode:

```powershell
.\scripts\Publish-Deployment.ps1 -ResourceGroupName <rg> -PlanOnly
```

Optional deeper validation can also exercise the upstream Function App package contract when you point the wrapper at a local `defender-reporting` checkout.

See [docs/validation.md](docs/validation.md) for details.