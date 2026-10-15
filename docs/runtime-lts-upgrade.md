# Hosted PowerShell runtime baseline

The wrapper selects PowerShell 7.6 / .NET 10 LTS for the existing Flex
Consumption Function App and creates `PowerShell-76-AzAccounts` for the
Automation publisher. The publisher explicitly binds its owned runbook to
that environment. Hosting topology, identity, permissions and export scope
are unchanged. Microsoft documents [Functions 7.6 support](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell#powershell-versions)
and [Automation runbook support](https://learn.microsoft.com/en-us/azure/automation/automation-runbook-types#powershell-runbooks).

## Immutable source and package boundary

The wrapper's source archive, released Function package and compatibility
locks are unchanged. The released Function package contains no 7.4 worker
selection; its runtime is selected by wrapper infrastructure. The locked
source archive contains historical upstream setup/runtime guidance for 7.4.
The wrapper does not execute that archived `Setup-AzureResources.ps1`; it
builds the runbook and selects its runtime through the wrapper publisher.
Changing or re-signing archived bytes would break the integrity contract.
A broader upstream release refresh needs its own contract review. No 7.6 live
validation is inferred from older source comments or package evidence.

## Live upgrade gates

An approved Automation publish creates a new runtime and rebinds the runbook;
the old environment is retained. This source patch does not provide a paused
migration procedure. The existing publisher unconditionally sets the daily
schedule's `isEnabled` to `true`, so it can re-enable processing and does not
preserve an existing pause. Do not assume pausing first and then running
normal publish keeps exports stopped until a later synthetic test.

Before live use, require a separately reviewed and explicitly authorized
paused-migration procedure covering the exact account/app, active jobs,
schedule/timer state, runtime/package imports, binding, worker startup,
synthetic validation and a separate resumption decision. That procedure is
not implemented by this source PR. A Function runtime configuration update
restarts the worker. Offline builds and tests do not prove Azure execution,
identity, Defender access, report delivery or performance. Do not deploy or
run live exports merely to validate this source PR.
