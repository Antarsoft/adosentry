# Contributing to PullPicket

Thanks for helping. Bug reports, fixes, rules-file examples and documentation are all welcome. For a larger change, such as a new parameter or a new model provider, open an issue first so we can agree on the approach before you write the code.

Please report security problems privately as described in [SECURITY.md](SECURITY.md), not in an issue.

## Repository layout

| Path | What it is | Language and checks |
| --- | --- | --- |
| `ai-code-review/` | The review engine and the stage template | PowerShell 7; Pester, PSScriptAnalyzer |
| `metrics/` | The optional metrics API and dashboard | Go; gofmt, go vet, go test, Docker build |
| `infra/` | Bicep and Entra scripts for the metrics service | Bicep build and lint, shellcheck |
| `tools/` | Maintenance scripts, such as the parameter reference generator | PowerShell 7; PSScriptAnalyzer |
| `docs/` | Guides linked from the README | |
| `examples/` | Example pipeline and rules files | |

## Local setup

You need:

- **PowerShell 7.4 or later** (`pwsh`), with the same module versions as CI:

  ```powershell
  Install-Module Pester -RequiredVersion 5.6.1 -Scope CurrentUser -Force -SkipPublisherCheck
  Install-Module PSScriptAnalyzer -RequiredVersion 1.23.0 -Scope CurrentUser -Force
  ```

- **Git** and **bash** (the engine shells out to both).
- **Go**, the version in [`metrics/go.mod`](metrics/go.mod), for anything under `metrics/`.
- Optional: **Docker** to build the metrics image, the **Bicep CLI** (0.48.1 in CI) and **shellcheck** for `infra/`, and **gitleaks** (8.30.1 in CI) to scan for secrets before you push.

You do not need an Azure subscription or an Azure DevOps organisation to run the checks. The Pester tests stub every Azure DevOps and model call, and the Go tests run against an in-memory Cosmos DB fake.

To try a change end to end, push your branch to a repository your Azure DevOps project can reach, point a test pipeline's `templates` resource at that branch (`ref: refs/heads/<your-branch>`), and open a pull request in a throwaway repository. Use placeholder code: never paste real customer code or real organisation names into issues, pull requests or test fixtures.

## Checks

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on every pull request, and all of it must pass before a merge. Run the parts you touched before you push.

**Engine (`ai-code-review/`, `tools/`):**

```powershell
Invoke-Pester -Path ai-code-review/tests
Invoke-ScriptAnalyzer -Path ai-code-review -Settings ai-code-review/PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path tools -Settings ai-code-review/PSScriptAnalyzerSettings.psd1
./tools/Update-ParameterReference.ps1 -Check
```

PSScriptAnalyzer must report zero findings. If you add, remove or change a parameter in `stage-template.yml`, describe it in a comment directly above its `- name:` line and regenerate [`docs/parameters.md`](docs/parameters.md):

```powershell
./tools/Update-ParameterReference.ps1
```

Every change to `stage-template.yml` needs a matching test in `ai-code-review/tests/Run-Summary.Tests.ps1`.

**Metrics API (`metrics/`):**

```bash
cd metrics
gofmt -l .          # must print nothing
go vet ./...
go test -race ./...
go build ./...
docker build metrics   # from the repository root, if you changed the Dockerfile or dependencies
```

Changes to the HTTP contract (paths, status codes, the event shape or `/metrics/summary`) need the contract tests in `metrics/contract_test.go` updated in the same change.

**Infrastructure (`infra/`):**

```bash
bicep build infra/main.bicep
bicep lint infra/main.bicep
shellcheck infra/*.sh
```

**Secrets:** `gitleaks git .` over your branch. CI scans the full history and fails on any finding.

## Pull requests

- Branch from `development` and open the pull request against `development`. `main` holds releases.
- Keep one pull request to one change. Small, focused commits inside it are easier to review than one large commit.
- Describe what changed and why, and how you tested it. Link the issue if there is one.
- Update the docs your change affects: the README, the files in `docs/`, the comments in `stage-template.yml`, and [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]` for anything a user would notice. Call out breaking changes in the changelog's "Changed (breaking)" section.
- Use placeholders (`<org>`, `<project>`, `contoso`, `00000000-0000-0000-0000-000000000000`) in code, tests and docs. No real organisation, tenant, subscription, host or person names.

## Commit style

- Write the subject in the imperative, about 50 to 70 characters, without a trailing full stop: `Skip the review stage on non-PR runs`, not `Skipped stage` or `fix: stage`.
- If the change closes a tracked item, put its ID at the end of the subject in brackets, such as `(E7)`.
- Leave a blank line, then explain in the body what changed and why, wrapped at about 72 characters. The diff shows how.
- Each commit should build and pass the checks on its own.
- End every commit with your sign-off (see below).

## Developer Certificate of Origin

PullPicket uses the [Developer Certificate of Origin](https://developercertificate.org/) (DCO) 1.1 instead of a contributor licence agreement. By signing off a commit you certify that you wrote the change, or otherwise have the right to submit it under the project's licence ([Apache 2.0](LICENSE)), and that the contribution and your sign-off are recorded publicly.

Sign off by adding this line to the end of every commit message, with your real name and an email address you can be reached at:

```
Signed-off-by: Your Name <you@example.com>
```

`git commit -s` adds it for you from your `user.name` and `user.email`. To sign off commits you have already made on your branch:

```bash
git rebase --signoff development
git push --force-with-lease
```

The **DCO sign-off** CI job checks every commit in a pull request (merge commits aside) for a `Signed-off-by` line with the commit author's email. Dependabot's commits and commits written by the maintainers' AI coding assistant are exempt; a maintainer reviews and merges those.

If your employer has rights to code you write, make sure you are allowed to contribute before you sign off.

## Licence

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the same licence as the project.
