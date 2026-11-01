# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (breaking)

- `foundryAuth` now defaults to `entra`: the review signs in to the model with the service connection's identity, which needs the Cognitive Services OpenAI User role. Set `foundryAuth: key` to keep using `foundry-key`; the key is now mapped into the step only in that mode.
- `promptMode` now defaults to `rules`: `promptFile` is a short rules file and the engine adds its shared base prompt. Set `promptMode: legacy` if `promptFile` is a complete prompt.
- The review stage now runs only for pull request builds (`Build.Reason` is `PullRequest`) and is skipped on CI, manual and scheduled runs.
- `Get-ExistingReviewThreads`, `Set-PullRequestComments` and `Get-ReviewFeedbackReport` take `-CollectionUri`; `-Organization` is now an optional fallback for dev.azure.com.

- The metrics container's partition key is now hierarchical, `/tenantId` then `/featureName` (`MultiHash`). Cosmos cannot change a container's partition key in place, so a container created from an earlier version of `infra/` has to be recreated.
- Metrics events take an optional `tenantId` (default `"default"`; letters, digits, `.`, `_` and `-`, up to 64 characters, otherwise `400`). `GET /metrics/summary` takes an optional `tenantId` with the same default and only reads that tenant's events; the dashboard pages pass `?tenantId=` through.

### Removed

- `AutoApprove` on `Set-PullRequestComments`, its reviewer vote call and the `auto-approved` outcome. The reviewer no longer approves pull requests.

### Fixed

- Reviews work on `*.visualstudio.com` organisations and Azure DevOps Server collections: REST URLs are built from `$(System.CollectionUri)` instead of a hard-coded `https://dev.azure.com/`.
- An unset `foundry-key` or `aiMetricsApiKey` variable is treated as empty instead of being sent as its literal `$(...)` text.
- A single quote in `promptFile`, `reviewPathSpec`, `reviewExcludePathSpec` or `foundryTokenResource` no longer breaks the inline script.
- Branch, project and repository names reach the inline script through environment variables, so a source branch name containing `$(...)` or a quote can no longer run code in the review step.

### Added

- GitHub Actions CI (`.github/workflows/ci.yml`): Pester tests and PSScriptAnalyzer for the engine, `gofmt`/`go vet`/`go test -race`/`go build` for the metrics API, and a gitleaks scan of the full history. Actions are pinned by commit SHA and the workflow token is read-only.
- Dependabot updates for GitHub Actions and Go modules.
- Bicep for the metrics store (`infra/main.bicep`, `infra/main.bicepparam`): a serverless Cosmos DB account with key-based auth disabled, database `AIMetrics` and container `Events` partitioned on `/featureName`.
- CI job that builds and lints every Bicep file under `infra/` with a version- and checksum-pinned Bicep CLI; linter levels live in `infra/bicepconfig.json`.
