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

## Why this is the current validation floor

The repo now owns the upstream Function App and Automation build contracts, but local validation still stops short of a live publish. That means local validation can already prove:

- `azure.yaml` hook inputs are normalized
- the wrapper scripts parse
- the Bicep matrix compiles
- the upstream Function App package contract still builds
- the upstream Automation runbook contract still builds

Optional live publish validation can now exercise the full Flex Consumption publish path, the Automation publish path, and the hosted Container App surface once a real Azure environment exists and the signed-in operator has blob data access to the wrapper storage account.
