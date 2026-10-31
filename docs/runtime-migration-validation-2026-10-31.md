# Runtime migration validation

The hosted runtime requirement is satisfied for the selected PowerShell 7.6
service offerings. On 2026-10-31, the upstream product deployment tools ran a
synthetic baseline, candidate and unchanged-store repeat on Flex Consumption
and Azure Automation. All six executions completed with the same three report
rows, two devices and three CVEs. Independent review checked full public-row
fields, including nested objects, arrays and nulls. Candidate Automation artifacts
also matched the recorded output hashes and service job identities.

The exact live-tested candidate was upstream commit
`1c715fe12adc0e4f6fa0cfd4cf0ada80bd95d8ba`. Flex reported PowerShell 7.6.9 /
.NET 10.0.14; Automation reported PowerShell 7.6.0-preview.5 / .NET 10.0.9.
The project owner accepts Azure's offered Automation 7.6 runtime. Its internal
preview label is retained as an observation, not an unresolved migration gate.

Published source/runtime bindings and schedule/timer states were read back.
The older baseline needed a supported schedule-disable PATCH before execution;
the candidate's explicit disable/readback succeeded. Both temporary test groups
were verified absent after cleanup. No real tenant exports or Graph/MDE workload
was used. The prior CLI default subscription was preserved.

Both Automation candidate executions missed the normalized payload cache.
This cache contains prepared report data, not dependencies or downloaded
templates. The cloud runbook creates a fresh temporary workspace, transfers
canonical exports rather than `.dashboard-cache`, and deletes its workspace
afterward. A miss is expected across these jobs: normalization runs again and
report generation continues. It is not a dependency-compatibility failure.

The wrapper now locks upstream commit
`69e5cfd53e5f1e6c8b762c86cb5b3967b3359e98`, a descendant containing later
import and harness changes. Contract review found no later changes to the hosted
runtime selections, package builders, canonical templates or hosted asset list.
Offline wrapper checks apply to the new exact pin. The earlier live observations
must not be presented as live execution of this newer commit or of the wrapper's
separate publication/validation adapters.

This refresh builds on wrapper draft #33 and inherits the existing reviewed
7.6 runtime, test baseline and publication changes from its dependency stack.
It does not duplicate that runtime migration, change permissions or start jobs.
The added optional publication-reader parameter is admitted by name while the
exact source-parameter check and the six-value synthetic job wire remain intact.
The template publisher also follows upstream's extracted canonical offline
helper file. Actual publisher regressions caught the old helper location before
publication; wrapper-owned authentication, uploads and validation remain intact.

For upstream issue #92, hosted runtime, small synthetic report correctness,
repeatability, schedule state and test-resource cleanup now have live evidence.
The repository-wide 7.6 source baseline and bespoke regression inventory were
already implemented upstream. Existing denied-permission and startup/dependency/
partial-failure acceptance items need reconciliation with retained offline tests;
they are not established by successful normal jobs. Clean-host/Windows-specific
coverage remains separately scoped. Private networking, real Defender exports,
performance and billing improvements are not claims of this migration evidence.

Raw operational receipts and identifiers remain local. No issue closure or new
live qualification is implied by this document.

## Offline checks for this refresh

PowerShell 7.6.9 / .NET 10.0.14 with existing Pester 6.2.0 passed all 366
existing and focused regression cases. Execution used 22 disjoint serial groups
under the unchanged 180-second, 3-GiB family and 3-GiB free-memory limits.
Reconciliation matched the complete discovered case-name/data multiset with no
missing, extra, failed, skipped or inconclusive cases. Filtered cases in one group
were accounted for in other groups. The 213 unaffected cases were retained;
all 153 publisher cases passed after the helper-path correction.

The old six-name source contract failed against the new runbook before its
correction. Five actual publisher cases then exposed the old helper location;
the same cases passed after the canonical-helper correction. Assertions and
test data were preserved. The original refused/capped/failed attempts remain
local and are not counted as passes.

The final default `Validate-Repository.ps1 -ValidateAllUpstreamContracts` gate
passed: environment defaults, parser, Bicep 0.42.1, Function rebuild, Automation
generation, template surface and hosted assets. Independent review verified the
source archive against all 218 Git blobs and every one of the Function package's
158 files against the build. All guards verified zero remaining owned processes.

Upstream's existing setup-runtime regression also passed at exact commit
`69e5cfd53e5f1e6c8b762c86cb5b3967b3359e98`: 67 classified 7.6 entrypoints,
five negative guard cases, static-expression side-effect rejection, generated
Function header, both runtime payloads and explicit Automation binding. These
checks execute no Azure setup, authentication or workload.
