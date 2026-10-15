# Hosted PowerShell runtime baseline

The wrapper uses PowerShell 7.6 / .NET 10 LTS for the Flex
Consumption Function App and creates `PowerShell-76-AzAccounts` for the
Automation publisher. The publisher explicitly binds its owned runbook to
that environment. Microsoft documents [Functions 7.6 support](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell#powershell-versions)
and [Automation runbook support](https://learn.microsoft.com/en-us/azure/automation/automation-runbook-types#powershell-runbooks).

## Immutable source and package boundary

The wrapper verifies the locked source archive, released Function package and
compatibility locks before publication. Wrapper infrastructure selects the
released Function package's runtime. The publisher builds the runbook from
the archive without executing its `Setup-AzureResources.ps1` and selects the
Automation runtime itself. Archived bytes and their integrity locks must be
updated together through the [upstream contract review](upstream-integration.md#updating-the-lock).
Package evidence does not establish live execution on the selected runtime.
