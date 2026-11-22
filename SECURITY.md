# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub Security Advisories
for this repository. Do not open a public issue containing tenant identifiers,
tokens, deployment output, or other sensitive telemetry. Include the affected
deployment mode, reproducible behavior, expected trust boundary, and suggested
mitigation when available.

Treat exposed credentials, federated identity configuration, or Function keys
as compromised and rotate or revoke them before reporting.

## Supported versions

No stable release or tag is currently published. The current default `main`
branch is the only supported line for security fixes. If a release is
published, its release notes will identify the supported version; older
releases receive fixes on a best-effort basis.

## Response targets

This project is maintained on a best-effort basis by a single maintainer. The
maintainer aims to acknowledge a private report within 7 calendar days and
provide an initial triage or next-steps decision within 14 calendar days.
These are targets, not a guarantee of emergency staffing or remediation time.

## Safe disclosure

Keep vulnerability details private until impact has been assessed and a fix,
mitigation, or coordinated disclosure decision is available. Do not publish
tenant identifiers, tokens, credentials, federated identity configuration,
Function keys, deployment output, or sensitive telemetry in public issues,
pull requests, examples, or release bundles.
