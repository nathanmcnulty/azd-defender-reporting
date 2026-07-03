# Deployment matrix

The wrapper keeps compute and web choices independent so future hosting additions do not force a redesign.

| `COMPUTE_KIND` | `WEB_KIND` | Resolved package mode when `DASHBOARD_PACKAGE_MODE=auto` | Current behavior |
| --- | --- | --- | --- |
| `functionapp` | `containerapp` | `hosted` | Provisions Flex Consumption Function App, storage, monitoring, and a managed-identity Container App that serves hosted dashboard blobs |
| `functionapp` | `none` | `selfcontained` | Provisions Flex Consumption Function App, storage, and monitoring only |
| `automation` | `containerapp` | `hosted` | Provisions Automation Account, storage, monitoring, and a managed-identity Container App that serves hosted dashboard blobs |
| `automation` | `none` | `selfcontained` | Provisions Automation Account, storage, and monitoring only |

## Notes

- `.\scripts\Publish-Deployment.ps1` is the wrapper-owned publish entrypoint. It reads the deployment mode, publishes templates once, and dispatches the matching compute and hosted publish paths.
- `dual` remains valid when you explicitly want both hosted and self-contained outputs.
- `hosted` is intentionally rejected when `WEB_KIND=none`.
- Function App publish now uses the upstream package contract and Flex Consumption OneDeploy semantics.
- Automation publish now uses the upstream runbook build contract, uploads templates, publishes `Invoke-DashboardPipeline`, and maintains the daily schedule.
- Hosted web publish now validates the blob-backed Container App host, configures Entra Easy Auth by default, applies security-group restriction when `HOSTED_AUTH_SECURITY_GROUP` / `-SecurityGroup` is supplied, and otherwise allows any authenticated user in the tenant. The explicit auth opt-out through `-SkipAuthSetup` / `SKIP_HOSTED_AUTH_SETUP=true` skips auth management and does not remove existing Easy Auth configuration.
