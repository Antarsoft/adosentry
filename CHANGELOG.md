# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The metrics API builds with Go 1.27 (`go.mod` and the Docker builder image `golang:1.27-alpine`). Replaces Dependabot PR #5, which bumped only the Dockerfile.
- The DCO sign-off CI job skips release pull requests into `main`. Their commits were already checked on their way into `development`, and the history includes commits from before sign-off was required.

### Fixed

- Dashboard: costs under one cent show as, for example, `$0.0023` instead of `$0.00`.
- Dashboard: the "Most-commented files" count column is now labelled "Reviews". It counts reviews that commented on the file, not individual comments.

## [1.0.0] - 2026-11-01

First release as PullPicket. The engine's `ModuleVersion` restarts at `1.0.0` (it was `7.0.0` under the old name). The dashboard's engine version table is unaffected: it shows the tag the pipeline checks the templates repository out at (such as `v1.0.0`), or the short commit when it points at a branch.

### Breaking defaults at a glance

Check these before you upgrade a pipeline or a metrics deployment. Each one is described in full under "Changed (breaking)" and "Removed" below.

| What | Before | 1.0.0 default | What to do |
|---|---|---|---|
| Name | AdoSentry | PullPicket (Go module `github.com/antarsoft/pullpicket/metrics`, Bicep prefix `pullpicket`) | Rename your repository resource and imports |
| `foundryAuth` | `key` | `entra` (needs Cognitive Services OpenAI User) | `foundryAuth: key` |
| `promptMode` | `legacy` | `rules` | `promptMode: legacy` |
| `AutoApprove` | Optional reviewer vote | Removed; the reviewer never approves | Approve by hand |
| `AUTH_MODE` (metrics service) | Not needed; `POST /events` was open | Required; the service will not start without it | `AUTH_MODE=none` for local development only |
| `metricsAuth` | API key | `entra` (token with the `Events.Write` app role) | `metricsAuth: key` |
| Engine functions | `-Organization` | `-CollectionUri` on `Get-ExistingReviewThreads`, `Set-PullRequestComments`, `Get-ReviewFeedbackReport` | `-Organization` still works as a dev.azure.com fallback |
| Metrics store and API | Partition key `/featureName`; `Access-Control-Allow-Origin: *`; `totalTokens.cached` always `0` | Partition key `/tenantId` + `/featureName` (recreate the container); no CORS headers unless `ALLOWED_ORIGINS` is set; `totalTokens.cached` sums `custom.cachedTokens` | Set `ALLOWED_ORIGINS` for a dashboard on another origin |

### Changed (breaking)

- The project is renamed from AdoSentry to PullPicket, because "Sentry" is a registered mark in developer tooling and the Visual Studio Marketplace asks for "Azure DevOps" in full rather than "ADO". Marketplace listings will be named "PullPicket for Azure DevOps". The Go module path is now `github.com/antarsoft/pullpicket/metrics`, the Bicep `namePrefix` and `application` tag default to `pullpicket`, and examples use `api://pullpicket-metrics` and `<project>/pullpicket`. Existing imports of the repository keep working under their own name; rename your copy and the `name:` in your pipeline's `resources.repositories` when you move to the new repository.

- `foundryAuth` now defaults to `entra`: the review signs in to the model with the service connection's identity, which needs the Cognitive Services OpenAI User role. Set `foundryAuth: key` to keep using `foundry-key`; the key is now mapped into the step only in that mode.
- `promptMode` now defaults to `rules`: `promptFile` is a short rules file and the engine adds its shared base prompt. Set `promptMode: legacy` if `promptFile` is a complete prompt.
- The review stage now runs only for pull request builds (`Build.Reason` is `PullRequest`) and is skipped on CI, manual and scheduled runs.
- `Get-ExistingReviewThreads`, `Set-PullRequestComments` and `Get-ReviewFeedbackReport` take `-CollectionUri`; `-Organization` is now an optional fallback for dev.azure.com.

- The metrics container's partition key is now hierarchical, `/tenantId` then `/featureName` (`MultiHash`). Cosmos cannot change a container's partition key in place, so a container created from an earlier version of `infra/` has to be recreated.
- Metrics events take an optional `tenantId` (default `"default"`; letters, digits, `.`, `_` and `-`, up to 64 characters, otherwise `400`). `GET /metrics/summary` takes an optional `tenantId` with the same default and only reads that tenant's events; the dashboard pages pass `?tenantId=` through.

- The metrics API no longer sends `Access-Control-Allow-Origin: *`. By default it sends no CORS headers (the dashboard is same-origin and senders are not browsers); set `ALLOWED_ORIGINS` to a comma-separated list of exact origins to allow a dashboard hosted elsewhere.
- `POST /events` rejects bodies over 64 KB with `413`.
- `POST /events` requires a credential. The metrics service will not start without `AUTH_MODE`: `entra` (an Entra access token with the `Events.Write` app role, settings `ENTRA_TENANT_ID` and `ENTRA_AUDIENCE`), `key` (`X-Api-Key` matching `METRICS_API_KEY`, at least 32 characters), `entra,key` (either), or `none` for local development. Missing or invalid credentials get `401`, a token without the role gets `403`. Reads, pages and `/healthz` are unchanged.
- The review stage authenticates to the metrics API with the new `metricsAuth` parameter, default `entra`: it gets a token for `aiMetricsApiResource` (the API's application ID URI, a new variable in the metrics variable group) with the service connection's identity. Set `metricsAuth: key` to keep sending `aiMetricsApiKey`; the key is now mapped into the step only in that mode.
- `GET /metrics/summary` now fills `totalTokens.cached` with the sum of the events' `custom.cachedTokens` (it was always `0`), and the review stage sends `cachedTokens` (prompt tokens served from the model's cache, a subset of `promptTokens`). Cost estimates do not discount cached tokens yet.

### Removed

- `AutoApprove` on `Set-PullRequestComments`, its reviewer vote call and the `auto-approved` outcome. The reviewer no longer approves pull requests.

### Fixed

- Reviews work on `*.visualstudio.com` organisations and Azure DevOps Server collections: REST URLs are built from `$(System.CollectionUri)` instead of a hard-coded `https://dev.azure.com/`.
- An unset `foundry-key` or `aiMetricsApiKey` variable is treated as empty instead of being sent as its literal `$(...)` text.
- A single quote in `promptFile`, `reviewPathSpec`, `reviewExcludePathSpec` or `foundryTokenResource` no longer breaks the inline script.
- Branch, project and repository names reach the inline script through environment variables, so a source branch name containing `$(...)` or a quote can no longer run code in the review step.

### Added

- The metrics API signs in to Cosmos DB with Microsoft Entra ID (`DefaultAzureCredential`: managed identity in Azure, Azure CLI locally) when `COSMOS_KEY` is unset. This is required for the account in `infra/`, which disables key auth. `COSMOS_KEY` still works as a fallback.
- Model prices for the metrics cost estimate live in `metrics/internal/pricing/pricing.json`; `PRICING_FILE` points the service at a replacement file. A malformed file stops the service at startup.
- The metrics API sets read, write, header and idle timeouts and shuts down gracefully on `SIGTERM`.
- The dashboard's Chart.js is compiled into the metrics binary and served from `/static/`; the dashboard no longer loads anything from a CDN.
- The metrics service is split into packages under `metrics/internal/` with characterisation tests for the HTTP contract (run against an in-memory Cosmos fake) and table-driven tests for aggregation, pricing and configuration.

- GitHub Actions CI (`.github/workflows/ci.yml`): Pester tests and PSScriptAnalyzer for the engine, `gofmt`/`go vet`/`go test -race`/`go build` for the metrics API, and a gitleaks scan of the full history. Actions are pinned by commit SHA and the workflow token is read-only.
- Dependabot updates for GitHub Actions and Go modules.
- Bicep for the metrics store (`infra/main.bicep`, `infra/main.bicepparam`): a serverless Cosmos DB account with key-based auth disabled, database `AIMetrics` and container `Events` partitioned on `/featureName`.
- CI job that builds and lints every Bicep file under `infra/` with a version- and checksum-pinned Bicep CLI; linter levels live in `infra/bicepconfig.json`.
- Full metrics deployment in `infra/`: a container registry (no admin user), a user-assigned identity with `AcrPull` and the Cosmos DB Built-in Data Contributor role, a Container Apps environment with Log Analytics, and the Container App with `AUTH_MODE`, `ENTRA_TENANT_ID` and `ENTRA_AUDIENCE` set. Container Apps sign-in with Entra guards everything except `/events` and `/healthz`. Steps, outputs and teardown are in `infra/README.md`.
- `infra/setup-entra.sh` registers the metrics API (with the `Events.Write` app role) and the dashboard sign-in app (assignment required), and `infra/grant-events-write.sh` gives a pipeline's service connection `Events.Write`. CI runs shellcheck on both.
- Documentation: a [parameter reference](docs/parameters.md) generated from `stage-template.yml` by `tools/Update-ParameterReference.ps1` (CI fails if it is stale), a [troubleshooting guide](docs/troubleshooting.md), a [metrics guide](docs/metrics.md), [SECURITY.md](SECURITY.md) with what the model and the metrics service receive and how to report a vulnerability, and [CONTRIBUTING.md](CONTRIBUTING.md).
- Contributions are signed off under the Developer Certificate of Origin; a `DCO sign-off` CI job checks pull request commits.

[Unreleased]: https://github.com/Antarsoft/pullpicket/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Antarsoft/pullpicket/releases/tag/v1.0.0
