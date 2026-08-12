# Validation

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
