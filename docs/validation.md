# Validation

Run the wrapper-owned validation entrypoint:

```powershell
.\scripts\Validate-Repository.ps1
```

It currently validates:

1. deployment-mode normalization and default resolution
2. PowerShell syntax for all scripts under `scripts/`
3. Bicep compilation through `az bicep build --file .\infra\main.bicep`

## Why this is the current validation floor

The repo now owns provisioning shape and wrapper contracts, but it does not yet own the final upstream package deployment contract. That means local validation can already prove:

- `azure.yaml` hook inputs are normalized
- the wrapper scripts parse
- the Bicep matrix compiles

Live publish validation will be added once the upstream Function App package surface lands.
