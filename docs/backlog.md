# Backlog: nathanmcnulty/azd-defender-reporting

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-defender-reporting
- **Source revision:** `b54b5d42d372d56a21238623e33e030740b8b5a1`
- **Captured:** 2026-10-03
- **Items:** 4

## REPORT-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** ready
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- _none_

**Agent handoff prompt:**

```text
Review REPORT-001 in docs/backlog.json and changes since backlog source revision b54b5d42d372d56a21238623e33e030740b8b5a1.
Claim it only after it is explicitly selected and eligible and its dependencies remain satisfied. Never interpret this generated prompt as approval.
Work only in nathanmcnulty/azd-defender-reporting, preserve its stated scope and acceptance gates, record the exact current base commit and one owned worktree in claim, run every validation entry, and record concrete evidence before marking it done.
Stop if the dependencies, scope, or required authorization changed.
```

## REPORT-004: Assess offline release packaging for the pinned-upstream deployment wrapper

- **Kind:** discovery
- **Priority:** P1
- **Status:** proposed
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open report captured 2026-10-03 during execution reconciliation. Another code-quality task may own an active fix; inspect its PR and current source before dispatch.

**Scope:**

- Linked issue and current source &lpar;read-only&rpar;
- Repository-local backlog evidence

**Acceptance:**

- Read the linked issue and current default branch; classify the exact defect, current owner and evidence gap.
- Record a current PR or verified resolution before selecting any implementation; preserve broader feature and live acceptance gates.

**Validation:**

- Read current issue and PR state using nathanmcnulty; do not modify or close issues during reconciliation.
- Inspect dirty state and worktrees; resolve the exact current revision and relevant offline commands before implementation.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-defender-reporting/issues/16

**Evidence:**

- _none_

**Review and authorization note:**

Review REPORT-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## REPORT-002: Qualify the locked compute and hosted-surface deployment matrix

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** azure-deployment
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The wrapper explicitly relies on a locked upstream package contract; generic azd template readiness is not established.

**Scope:**

- contracts/
- scripts/
- docs/deployment-matrix.md

**Acceptance:**

- Verify Function and Automation package provenance, manifest failures and exact upstream revision.
- For each supported compute/web mode retain job success, hosted asset identity and Easy Auth enforcement evidence.
- Document unsupported combinations and teardown; preserve the explicit upstream dependency instead of a false self-contained claim.

**Validation:**

- From the solution root run ./scripts/Validate-Repository.ps1
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md
- docs/deployment-matrix.md

**Evidence:**

- _none_

**Review and authorization note:**

Review REPORT-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## REPORT-003: Evaluate optional WebApp hosting without forking upstream reporting

- **Kind:** discovery
- **Priority:** P2
- **Status:** proposed
- **Wave:** 3
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

WebApp is a documented future surface; the shared Maester web module has application-specific assumptions.

**Scope:**

- infra/
- scripts/Publish-HostedSurface.ps1
- docs/deployment-matrix.md

**Acceptance:**

- Produce adopt/adapt/defer decision comparing blob-backed Container App with WebApp identity, Easy Auth and asset contracts.
- Keep upstream exporter/dashboard source authoritative and compute/web selection independent.
- Do not vendor maester-report-webapp unchanged unless its Maester-specific behavior is compatible; define a narrow shared extraction only with two consumers.

**Validation:**

- From the solution root run ./scripts/Validate-Repository.ps1

**Dependencies:**

- _none_

**Components:**

- maester-report-webapp

**Sources:**

- README.md
- docs/deployment-matrix.md

**Evidence:**

- _none_

**Review and authorization note:**

Review REPORT-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
