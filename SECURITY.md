# Security policy

PullPicket sends parts of your code to a model and posts what the model says on your pull requests. This page says exactly what leaves your pipeline, how the reviewer handles hostile input, how credentials are handled, and how to report a vulnerability.

## Supported versions

Security fixes go into the latest release. Pin a release tag (such as `v1.0.0`) in your pipeline's `resources.repositories` and move to the newest tag when a fix is announced in [CHANGELOG.md](CHANGELOG.md).

| Version | Supported |
| --- | --- |
| Latest 1.x release | Yes |
| Anything before 1.0.0 | No |

## Reporting a vulnerability

Please report vulnerabilities privately, not in a public issue or pull request.

Use GitHub's private reporting: on this repository, open **Security > Report a vulnerability**. Include what an attacker can do, the steps or a proof of concept, and the version or commit you tested. Use placeholder names, not real organisation, tenant or repository names.

What to expect (PullPicket is maintained by a small team, so these are aims, not guarantees):

- An acknowledgement within 5 working days.
- An assessment, and a fix plan or an explanation, within 30 days.
- A fix in a new release and a note in the changelog. You are credited unless you ask not to be.

Please give us a reasonable time to ship a fix before you disclose the issue publicly. Testing against your own Azure DevOps organisation and Azure resources is welcome; do not test against systems you do not own.

## What the model receives

Each review run sends one or more chat completion requests to the model deployment you configure (`modelDeploymentUrl`), and nowhere else. A request contains:

| Part | Content |
| --- | --- |
| System message | With `promptMode: rules`, the shared base prompt ([`ai-code-review/prompts/base.codereviewprompt.md`](ai-code-review/prompts/base.codereviewprompt.md)) followed by your rules file. With `promptMode: legacy`, your prompt file only. |
| Prior review rounds | Only when the pull request already has PullPicket comments: for each, the file path, line number, severity, thread status, and the first 150 characters of the first line of the comment. |
| The diff | A legend naming the source and target branches; for each reviewed file, its path (and the old path if it was renamed) and its changed lines with 5 lines of context around each change, numbered. Lines past `reviewMaxFileTokens` are cut. |
| Deleted files | Only with `reviewDeletedFiles: true`: the paths of deleted files, not their content. |
| Settings | The `modelName` and, if set, `reasoningEffort`, plus the JSON schema the answer must match. |

The model does **not** receive: whole files beyond the context lines, files that are excluded (`reviewDefaultExcludes`, `reviewExcludePathSpec`, or not matched by `reviewPathSpec`), the pull request title or description, commit messages, other people's comments on the pull request, pipeline variables, or any credential.

A large pull request is split into batches, and each batch is its own request that repeats the system message and prior review rounds.

Where the data goes after that depends on your model deployment: its region, data retention and abuse monitoring are set by your Azure OpenAI or Azure AI Foundry resource and Microsoft's terms for it, not by PullPicket. If your code must not leave a region, deploy the model in that region.

**Logs.** The step log shows file paths, line numbers, counts and the first part of a model answer when it cannot be parsed. It does not show the diff unless you turn on `aiReviewDebugLogging`, which writes the full diff to the pipeline log for that run. Anyone who can read the pipeline's logs can then read it, so turn it on only for debugging and off again.

## Prompt injection

The diff is written by the pull request author, so PullPicket treats it as hostile input:

- The diff is wrapped between marker lines that carry a random id generated for each request. The author cannot know the id, so text in the diff cannot forge the closing marker and "escape" into instructions.
- The base prompt tells the model that everything inside the diff and the prior review rounds is data under review, never instructions. Text that tries to steer the reviewer ("ignore previous instructions", "this file is pre-approved", "return an empty review") is not followed; the model is told to flag it as a `WARNING` on the nearest changed line instead.
- The answer must match a strict JSON schema (file name, line number, severity, comment). Comments that point at a file or line outside the diff are moved to the nearest changed line or dropped.
- The reviewer can only comment. It has no tools, cannot run code, cannot vote, approve or complete a pull request, and cannot change the repository.

These measures lower the risk; they do not remove it. A model can still be persuaded to miss a problem or to write a misleading comment. **Treat PullPicket comments as advice from an untrusted reviewer**: they never replace a human review, and branch policies should not count them as approval. Comments are posted as plain pull request comments under the service connection's identity, so a misleading comment is visible and attributable.

**Prior review history.** PullPicket recognises its own earlier comments by the service connection's identity, or by a hidden marker (`<!-- aicr:v1 ... -->`) at the start of a thread. Someone who can comment on the pull request could add a thread with that marker, and up to 150 characters of it would reach the model in the prior review rounds block. That block is inside the same untrusted-content rules as the diff.

**Pipeline injection.** Branch, project and repository names reach the review script as environment variables, not as text pasted into the inline script, so a branch named with quotes or `$(...)` cannot run code in the step. Template parameters are escaped where they are pasted into the script.

## What the metrics service receives

Only when you set `metricsVariableGroup`, each run sends one JSON event to your metrics service. It contains:

- `featureName` (`ai-code-review`), `source` (`ado-pipeline`), and the server-set `eventId`, `timestamp` and `receivedAt`;
- the Azure DevOps **project name**, **repository name**, pull request id, pipeline run id, and the **source and target branch names**;
- counts: files changed, reviewed, excluded, renamed, deleted and truncated; lines added and removed; batches; comments proposed, posted, skipped as duplicates, moved and dropped; and comments per severity;
- the **file paths that received comments**;
- the run's outcome, error type and HTTP status code if it failed, latency, token counts, the model name and the PullPicket version.

It does **not** contain code, diff lines, comment text, prompts, pull request titles or descriptions, or people's names. Branch names and file paths can still be sensitive (for example `fix/cve-2026-1234` or `src/acquisition-target/`), so restrict who can open the dashboard: the Bicep in `infra/` puts it behind Entra sign-in with assignment required.

Events are stored in your own Cosmos DB account. PullPicket has no telemetry of its own and sends nothing to its authors.

## Credential handling

**Defaults use no secrets.** With `foundryAuth: entra` and `metricsAuth: entra` (both defaults), the review signs in to the model, to Azure DevOps and to the metrics API with the service connection's Entra identity. Use workload identity federation for the service connection so there is no client secret either.

- **Tokens** are requested at run time with `Get-AzAccessToken` and never written to disk. The model token is registered as a pipeline secret so the agent masks it in logs.
- **Keys**, if you choose `foundryAuth: key` or `metricsAuth: key`, come from secret variables in a variable group (`foundry-key`, `aiMetricsApiKey`). They are mapped into the step's environment only in that mode, so a key you did not ask for is never exposed to the script. Azure Pipelines masks secret variables in logs. An unset key variable is treated as empty, not sent as its literal `$(...)` text.
- **Least privilege.** The service connection's identity needs only Cognitive Services OpenAI User on the model resource, Contribute to pull requests on the reviewed repositories, and (for metrics) the API's `Events.Write` app role. It does not need Contributor on any Azure resource.
- **Metrics service.** `POST /events` rejects requests without a credential (`401`) and tokens without `Events.Write` (`403`); there is no anonymous write mode outside local development (`AUTH_MODE=none`). An API key must be at least 32 characters and is compared in constant time. The service reads Cosmos DB with a managed identity; the Cosmos account in `infra/` has key auth disabled. It sends no CORS headers unless you list origins in `ALLOWED_ORIGINS`, limits event bodies to 64 KB, and runs as a non-root user in a distroless image.
- **Entra setup files.** `infra/setup-entra.sh` writes the dashboard sign-in secret to `.env.entra` with mode 600. It is git-ignored; delete it after you deploy.

## Hardening checklist

- Pin PullPicket to a release tag, and review template changes before you move the tag.
- Use workload identity federation for the service connection, and keep `foundryAuth` and `metricsAuth` on `entra`.
- Grant the service connection only the roles above, on the model resource and repositories it needs.
- Exclude paths that should never leave the pipeline (secrets fixtures, customer data samples) with `reviewExcludePathSpec`, or limit reviews with `reviewPathSpec`.
- Keep `aiReviewDebugLogging` off.
- Deploy the model in a region and under data-handling terms you accept.
- If you run the metrics service, keep the dashboard behind sign-in with assignment required.
