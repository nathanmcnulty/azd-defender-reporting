# Upstream integration

This wrapper does not carry a copy of `defender-reporting`. Instead it resolves the upstream source at execution time.

## Resolution order

`Resolve-UpstreamRepo.ps1` uses:

1. `DEFENDER_REPORTING_PATH` when you already have a local checkout
2. a local cache under `.local\upstream\defender-reporting`
3. `DEFENDER_REPORTING_REPO` + `DEFENDER_REPORTING_REF` to hydrate or refresh that cache

## Defaults

If not set, the wrapper defaults to:

- `DEFENDER_REPORTING_REPO=https://github.com/nathanmcnulty/defender-reporting.git`
- `DEFENDER_REPORTING_REF=main`

## Why this wrapper uses a pinned-source model

- It keeps this repo thin.
- It avoids submodule churn while upstream is actively changing.
- It gives local development a clean override path.
- It makes later CI adoption straightforward because the wrapper can pin a specific ref.

## Current blocker

The wrapper is waiting for the upstream repo to expose a **first-class Function App package build surface** with a stable manifest or output path. Until that lands, the Function App publish script in this repo fails on purpose with a contract error instead of trying to infer internal upstream file layout.

