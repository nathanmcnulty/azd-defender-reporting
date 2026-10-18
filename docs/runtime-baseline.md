# Hosted PowerShell runtime baseline

Owned scripts and tests require PowerShell 7.6 or later. Repository tests use
Pester 6.2.0. The three workflows that run repository PowerShell select the official SHA-256-verified portable
PowerShell 7.6.6 Windows x64 runtime and log its actual version before repository
work. The runner's preinstalled shell only bootstraps that selection; it is not
a supported runtime for the wrapper. Upstream archives remain frozen evidence.

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

## Offline baseline evidence

The 2026-10-18 Windows retest used PowerShell 7.6.6, .NET 10.0.12 and Pester
6.2.0: all seven bundled-release/runtime tests passed with zero failed, skipped,
inconclusive or unexecuted cases. Full `Validate-Repository.ps1
-ValidateAllUpstreamContracts` passed, including parsing, Bicep 0.42.1,
Function package rebuild, Automation runbook generation, template publisher and
hosted asset contracts. Both vendored ZIPs and every compatibility lock remained
unchanged. No Azure deployment, authentication or live workload ran.

That local full gate took approximately 22.7 seconds: Bicep 7.5 seconds,
Function package work 9.0 seconds, Automation generation 2.4 seconds and the
remaining stages approximately 3.9 seconds. These are one machine's observations,
not performance guarantees. The complete gate is retained.
