# Optional Web App compatibility assessment

REPORT-003 decision, 10 October 2026: **defer unchanged adoption** of
`maester-report-webapp` 0.1.1. The module provisions an App Service static-file
host, but does not implement this wrapper's Blob asset synchronization, hosted
identity permissions or Container App Easy Auth contract. This assessment does
not add a Web App option or choose a hosting migration.

## Exact evaluated sources

The wrapper base is
[`8f258252417cb9f675a8b1ec3a8649582bdca91c`](https://github.com/nathanmcnulty/azd-defender-reporting/tree/8f258252417cb9f675a8b1ec3a8649582bdca91c).
The evaluated Reference pin is
`29bcc4c8f08855b35f7a357dd2c8c8819824ce7c`, with its
[pilot manifest](https://github.com/nathanmcnulty/azd-reference/blob/29bcc4c8f08855b35f7a357dd2c8c8819824ce7c/components/bicep/maester-report-webapp/component.json)
and [Web App module](https://github.com/nathanmcnulty/azd-reference/blob/29bcc4c8f08855b35f7a357dd2c8c8819824ce7c/components/bicep/maester-report-webapp/maester-report-webapp.bicep).
The complete component directory is unchanged through inspected Reference main
`277584b33fcae7d47113718aad6428abdc4bc50f`. This is an evaluated candidate pin,
not an adopted component lock or deployment instruction.

## Contracts compared

| Boundary | Current blob-backed Container App | Evaluated Maester Web App | Missing compatibility contract |
| --- | --- | --- | --- |
| Report assets | Reads the contract-selected dashboard Blob and required/optional assets into local content; retains its synchronization loop and placeholder behavior | Serves `/home/site/wwwroot` with `pm2` and SPA routing | A solution-owned publisher or Blob synchronization adapter must preserve exact paths, required-file failure behavior, relative asset URLs and gzip payload handling |
| Reader identity | System-assigned Container App identity receives scoped Storage Blob Data Reader | System identity is optional and disabled by default; no Blob reader assignment is supplied | Explicit identity selection, exact storage/container binding and reader role ownership must be designed before any deployment |
| Publisher authority | Compute publishing and template publishing use the upstream package/build contract | Optional publisher gets Website Contributor on the Web App | Website Contributor does not supply runtime Blob read authority or define the dashboard's asset publication contract |
| Easy Auth | Wrapper-owned auth setup configures the Container App with tenant sign-in and optional security-group restriction; an explicit skip preserves existing auth | The Bicep component has no matching Easy Auth configuration or tenant/group adapter | App Service auth, redirect/app binding, tenant/audience/group behavior, secret custody and owned-object cleanup need their own reviewed adapter |
| Deployment and cleanup | Current wrapper records its compute/web choices and uses solution-owned publishers | Optional Maester-tagged host with delete locks enabled by default | Host tags, locks, publication ownership and teardown must be reconciled; copying the component is not proof of safe removal |
| Upstream authority | Exporter/dashboard assets originate from the integrity-bound upstream release | Component provisions infrastructure and a local file-serving command | Keep upstream generation authoritative; do not fork reporting logic to fit the host |

Current source evidence:

- [Container App host](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/infra/modules/web-containerapp.bicep)
  and [role assignments](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/infra/modules/role-assignments.bicep).
- [Hosted asset contract](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/contracts/hosted-assets.json),
  [host publisher](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/scripts/Publish-HostedSurface.ps1)
  and [auth adapter](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/scripts/Set-HostedSurfaceAuth.ps1).
- [Upstream lock](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/contracts/upstream-lock.json)
  binds upstream `defender-reporting` release `v2026.07.13` to commit
  `28c68b4ea5521f834884a8f7aad9cfb38f1588b8`; the separate
  [bundled source contract](https://github.com/nathanmcnulty/azd-defender-reporting/blob/8f258252417cb9f675a8b1ec3a8649582bdca91c/contracts/upstream-package.json)
  records exact archive integrity.

## Decision and reconsideration

Keep `COMPUTE_KIND=functionapp|automation` independent of
`WEB_KIND=containerapp|none`, with the current package-mode rules preserved.
This assessment neither changes those choices nor adds `WEB_KIND=webapp`.
A future Web App would require the missing adapters above and explicit optional
permission, auth, rollback and ownership evidence before implementation.

No generic shared extraction is justified by this comparison alone. Prove the
same narrow need in two real consumers before proposing one. Maester remains a
different report/asset consumer; this wrapper must not absorb or fork upstream
exporter/dashboard source to obtain infrastructure reuse.

Run the registered `pwsh -File ./scripts/Validate-Repository.ps1` with
PowerShell 7.6 or later. Bundled-release Pester tests and
`-ValidateAllUpstreamContracts` additionally check the existing upstream source,
package and hosted-asset contracts offline. Canonical backlog checks bind this
decision to REPORT-003. These checks do not prove App Service compatibility,
live Easy Auth, browser rendering, Blob delivery or safe deployed cleanup.
