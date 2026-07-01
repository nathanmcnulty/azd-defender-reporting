# Validation

Run the wrapper-owned validation entrypoint:

```powershell
.\scripts\Validate-Repository.ps1
```

It currently validates:

1. deployment-mode normalization and default resolution
2. PowerShell syntax for all scripts under `scripts/`
3. Bicep compilation through `az bicep build --file .\infra\main.bicep`

You can also validate the real upstream Function App package integration when you have a local `defender-reporting` checkout:

```powershell
.\scripts\Validate-Repository.ps1 `
    -ValidateFunctionAppPackage `
    -UpstreamRepositoryPath C:\path\to\defender-reporting
```

## Why this is the current validation floor

The repo now owns the upstream Function App package contract, but local validation still stops short of a live Flex publish. That means local validation can already prove:

- `azure.yaml` hook inputs are normalized
- the wrapper scripts parse
- the Bicep matrix compiles

Optional live publish validation can now exercise the full Flex Consumption publish path once a real Azure environment exists and the signed-in operator has blob data access to the deployment storage container.
