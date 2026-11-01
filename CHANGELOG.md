# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- GitHub Actions CI (`.github/workflows/ci.yml`): Pester tests and PSScriptAnalyzer for the engine, `gofmt`/`go vet`/`go test -race`/`go build` for the metrics API, and a gitleaks scan of the full history. Actions are pinned by commit SHA and the workflow token is read-only.
- Dependabot updates for GitHub Actions and Go modules.
