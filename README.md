# azd-defender-reporting

Thin Azure Developer CLI wrapper for [`nathanmcnulty/defender-reporting`](https://github.com/nathanmcnulty/defender-reporting).

This repo is intentionally **not** a fork of the dashboard application. The upstream repo remains the source of truth for export, dashboard generation, and Azure package build logic. This wrapper owns:

- `azure.yaml` workflow orchestration
- `infra/` Bicep provisioning
- `scripts/` PowerShell validation, upstream resolution, and publish orchestration
- wrapper-specific docs and deployment contracts

## Current scope

The initial scaffold is meant to be runnable for:

- `azd provision`
- local structural validation of the wrapper contract
- mode selection across Function App vs Automation Account and Container App vs no-web

The final **Function App publish** path is intentionally gated on the upcoming upstream first-class package surface. The placeholder publish scripts in this repo fail clearly so the missing upstream contract is obvious instead of being hidden behind ad-hoc probing.

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
   ```

4. Run the local wrapper validation.

   ```powershell
   .\scripts\Validate-Repository.ps1
   ```

5. Provision infrastructure.

   ```powershell
   azd provision
   ```

At this stage the wrapper provisions the Azure resource matrix and validates the local contracts, but it does **not** yet complete the upstream Function App package deployment. That final publish step is blocked on the upstream package manifest surface.

## Files added by this scaffold

- `azure.yaml` - azd workflow and hook registration
- `infra/` - Bicep modules for storage, monitoring, Function App, Automation Account, and Container App
- `scripts/` - validation, mode normalization, upstream resolution, and placeholder publish commands
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

See [docs/validation.md](docs/validation.md) for details.