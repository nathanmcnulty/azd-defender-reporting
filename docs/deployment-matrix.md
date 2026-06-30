# Deployment matrix

The wrapper keeps compute and web choices independent so future hosting additions do not force a redesign.

| `COMPUTE_KIND` | `WEB_KIND` | Resolved package mode when `DASHBOARD_PACKAGE_MODE=auto` | Current scaffold behavior |
| --- | --- | --- | --- |
| `functionapp` | `containerapp` | `hosted` | Provisions Flex Consumption Function App, storage, monitoring, and placeholder Container App |
| `functionapp` | `none` | `selfcontained` | Provisions Flex Consumption Function App, storage, and monitoring only |
| `automation` | `containerapp` | `hosted` | Provisions Automation Account, storage, monitoring, and placeholder Container App |
| `automation` | `none` | `selfcontained` | Provisions Automation Account, storage, and monitoring only |

## Notes

- `dual` remains valid when you explicitly want both hosted and self-contained outputs.
- `hosted` is intentionally rejected when `WEB_KIND=none`.
- Final Function App publish wiring is blocked on the upstream package contract.
- Publish scripts for Automation and hosted web are placeholders in this scaffold; provisioning is ready, deployment wiring comes next.

