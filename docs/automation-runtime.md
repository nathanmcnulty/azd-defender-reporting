# Automation runtime provenance

`contracts/automation-runtime.json` binds the PowerShell runtime, environment name
and exact Az.Accounts package version, URL, byte size and SHA-256. Version 5.5.0 is
also present in the existing SHA-256-locked Function release. Its module files were
compared with the exact Gallery package before selecting this pin. This does not
change that release, the upstream source lock or its retained older module version.

The maintained Automation publisher includes this contract and its byte digest in
the generated runbook manifest and BuildOnly result. BuildOnly remains offline.
The generated runbook is snapshotted as bytes; its manifest hash/size and draft
upload use that same snapshot, preserving its UTF-8 BOM and exact byte identity.
Publication sends a versioned URL, content version and SHA-256 contentHash using
the [package import API](https://learn.microsoft.com/en-us/rest/api/automation/package/create-or-update?view=rest-automation-2024-10-23).
It waits for Succeeded, rejects Failed/Canceled or a different imported version,
and checks the runtime and complete package inventory before publishing the runbook.
Created is an intermediate state, not import success. A failed import is not retried
with an unversioned URL or without the hash.

The supervised validation context must bind RuntimeContractSha256. Its preflight
checks the published runbook's runtime name, language/version, empty defaultPackages
and exactly one non-default Az.Accounts package at the locked version in Succeeded
state. Additional packages, continuation links, malformed metadata and source
contract drift fail closed before job submission.

The [package GET API](https://learn.microsoft.com/en-us/rest/api/automation/package/get?view=rest-automation-2024-10-23)
reports version and import status; these are metadata readbacks, not independent
measurements of the installed module bytes. The requested contentHash enforcement,
native import behavior and PowerShell/module compatibility still require approved
Azure qualification. Preserve the import request, source contract, deployment
receipt and runtime/job evidence together; no offline test establishes native
dependency acceptance. Publication and validation remain separate, explicitly
approved operations. No identity, permissions or schedules are created by reading
the contract or planning validation.
