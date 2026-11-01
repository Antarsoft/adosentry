# Metrics service and dashboard

The metrics service is optional. Without it, PullPicket still reviews pull requests and prints a one-line summary in each run's log. With it, every review run sends one event, and a dashboard shows reviews, comments, severities, errors, tokens, latency and estimated cost over time.

The service is a small Go program in [`metrics/`](../metrics) that stores events in Cosmos DB. It has one write endpoint and a few reads:

| Endpoint | Who calls it | Auth |
| --- | --- | --- |
| `POST /events` | the review stage (or any sender) | a credential, set by `AUTH_MODE` (see [Authentication](#authentication)) |
| `GET /`, `GET /dashboard?feature=ai-code-review` | people, in a browser | Container Apps sign-in with Entra, in Azure |
| `GET /metrics/summary`, `GET /metrics/features` | the dashboard page | Container Apps sign-in with Entra, in Azure |
| `GET /healthz` | the platform's probe | none |

Contents:

- [Deploy](#deploy)
- [Connect the pipeline](#connect-the-pipeline)
- [Authentication](#authentication)
- [Using the dashboard](#using-the-dashboard)
- [Pricing file](#pricing-file)
- [Configuration reference](#configuration-reference)
- [Run it locally](#run-it-locally)
- [Troubleshooting](#troubleshooting)

## Deploy

[`infra/README.md`](../infra/README.md) has the full steps. In short, from the repository root:

1. `az deployment group create --resource-group <rg> --parameters infra/main.bicepparam` creates Cosmos DB (key auth disabled), a container registry, a user-assigned managed identity with its roles, and a Container Apps environment. It prints `metricsUrl`, the address the app will get.
2. `infra/setup-entra.sh --app-url <metricsUrl>` registers two Entra apps: the API, with the `Events.Write` app role, and the dashboard sign-in app. It writes their IDs to `.env.entra` (git-ignored).
3. `az acr build` builds the image in the registry.
4. A second `az deployment group create`, with `.env.entra` sourced and the image tag set, deploys the app with sign-in in front of it.
5. `infra/grant-events-write.sh --principal <service connection client id>` lets your pipeline write events.

The Bicep defaults to `authMode: entra`. Everything is in one resource group, so `az group delete` (plus deleting the two app registrations) removes it.

You can also run the image anywhere else that can reach Cosmos DB. Set the environment variables in the [configuration reference](#configuration-reference), and put your own sign-in in front of the reads: without Container Apps sign-in, the dashboard and `/metrics/*` are open to anyone who can reach the service.

## Connect the pipeline

Create a variable group (Pipelines > Library), for example `ai-code-review-metrics`, and pass its name to the stage:

```yaml
stages:
  - template: ai-code-review/stage-template.yml@templates
    parameters:
      azureSubscription: 'my-ai-review-connection'
      promptFile: 'pipelines/ai-code-review/my-repo.rules.md'
      metricsVariableGroup: 'ai-code-review-metrics'
      metricsAuth: entra          # the default; use key for the API key
```

| Variable | With | Value |
| --- | --- | --- |
| `aiMetricsApiUrl` | always | The service's base URL (`metricsUrl`), without `/events`. |
| `aiMetricsApiResource` | `metricsAuth: entra` | The API's application ID URI, such as `api://pullpicket-metrics` (`PULLPICKET_API_APP_ID_URI` in `.env.entra`). |
| `aiMetricsApiKey` | `metricsAuth: key` | The service's `METRICS_API_KEY`. Mark it secret. |

If `metricsVariableGroup` is empty or the group has no `aiMetricsApiUrl`, the stage skips the event. A failed event is logged as a warning and never fails the review.

## Authentication

`POST /events` always needs a credential. `AUTH_MODE` picks which kind the service accepts. It has no default: the service will not start without it.

| `AUTH_MODE` | The sender sends | Use it when |
| --- | --- | --- |
| `entra` | `Authorization: Bearer <token>`, an Entra access token for the API | Your pipelines run as an Azure service connection. Recommended; no secret to rotate. |
| `key` | `X-Api-Key: <key>` | A sender cannot get an Entra token, such as a job outside Azure. |
| `entra,key` | either | You are moving from the key to Entra, or have both kinds of sender. |
| `none` | nothing | Local development only. The service logs a warning at startup. |

Missing or wrong credentials get `401`. A valid token without permission gets `403`.

### Entra

The service checks the token's signature against the tenant's signing keys, its issuer (`ENTRA_TENANT_ID`), its audience (`ENTRA_AUDIENCE`) and its expiry. Then it checks the caller may write: the token must carry the API's **`Events.Write`** app role, or come from a principal listed in `ENTRA_ALLOWED_PRINCIPALS` (object ids or client app ids). Without one of these, any identity in the tenant could get a token for the API, so the role check is what keeps writes to the pipelines you chose.

To let a pipeline write:

```bash
infra/grant-events-write.sh --principal <service-connection-client-id>
```

Then set `metricsAuth: entra` (the default) and `aiMetricsApiResource` in the variable group. The stage asks Azure for a token for that resource with the service connection's identity, the same sign-in it uses for the model.

### API key

Generate a key of at least 32 characters, and give the same value to the service and the senders:

```bash
openssl rand -base64 32
```

- In Azure, pass it to the deployment as `metricsApiKey` (with `authMode: key` or `entra,key`); the Bicep stores it as a Container Apps secret. Read it from an environment variable rather than writing it in a file.
- In the pipeline, store it as the secret variable `aiMetricsApiKey` and set `metricsAuth: key`.

To rotate it, switch to `entra,key` while you change senders, or accept a short gap: update the service, then the variable group.

### Test a credential

[`metrics/scripts/send-event-curl.sh`](../metrics/scripts/send-event-curl.sh) sends a test event:

```bash
# Entra, with your Azure CLI sign-in (your account needs Events.Write, or use a service principal that has it)
AI_METRICS_API_URL=<metricsUrl> AI_METRICS_RESOURCE=api://pullpicket-metrics metrics/scripts/send-event-curl.sh

# API key
AI_METRICS_API_URL=<metricsUrl> AI_METRICS_API_KEY=<key> metrics/scripts/send-event-curl.sh
```

A test event shows up on the dashboard like a real run.

## Using the dashboard

Open `<metricsUrl>/` and sign in. The landing page lists the dashboards this deployment serves; for PullPicket that is `ai-code-review`, at `<metricsUrl>/dashboard?feature=ai-code-review`.

Pick a window (7, 14, 30 or 90 days, or all time) at the top. The page then shows:

| Panel | What it tells you |
| --- | --- |
| Headline tiles | Reviews with and without comments, errors, partial reviews (some batches failed), error rate, estimated cost, average and p95 latency, and the dedup rate (proposed comments dropped because the pull request already has them). Hover a tile for its definition. |
| PRs reviewed per day | Volume over time. Every day in the window is shown, so quiet days read as zero. |
| PRs reviewed by repository, and the By repository table | Where the reviews happen, average comments per pull request, how many reviews had no comments, and errors per repository. |
| Est. cost per day | Spend over time, from the [pricing file](#pricing-file). |
| Latency per day (p50 vs p95) | Time spent waiting on the model per run. A rising p95 usually means bigger pull requests or throttling. |
| Comment severity breakdown | `CRITICAL`, `WARNING` and `SUGGESTION` counts. Mostly suggestions can mean the rules file is too loose. |
| Most-commented files | The files the reviewer flags most, per repository. The count is the number of reviews that left at least one comment on the file, not the number of comments. |
| Errors by type | Failed runs by cause, such as `llm-api-error`, `input-too-large`, `truncated-response`, `content-filtered` or `post-failed`. See [troubleshooting](troubleshooting.md#other-errors). |
| By engine version, By model | Runs, errors, latency, tokens and cost per PullPicket version and per model deployment, to compare a change before and after. |

**Tenants.** Events can carry an optional `tenantId` (default `default`). Each tenant's events are stored and summarised separately, and the dashboard shows one tenant at a time: add `&tenantId=<id>` to its URL. A single-team deployment can ignore this.

## Pricing file

Cost is an estimate: tokens times a per-model rate. Rates are in US dollars per million tokens and are keyed by the `model` field of each event, which is the stage's `modelName` variable (your deployment name):

```json
{
  "models": {
    "my-gpt-deployment": { "inputPerMillion": 0.25, "outputPerMillion": 2.00 }
  }
}
```

- `inputPerMillion` prices `promptTokens`. Cached prompt tokens are not discounted yet, so the estimate is an upper bound when the cache hit rate is high.
- `outputPerMillion` prices `completionTokens`, which already include reasoning tokens.
- A model that is not in the file costs $0. Its runs and tokens still count. Because deployment names are yours, you will usually need your own file.
- Each event is priced with its own model, so switching models does not change past costs.

The built-in rates are in [`metrics/internal/pricing/pricing.json`](../metrics/internal/pricing/pricing.json) and are compiled into the binary. To use your own:

- **Edit the built-in file** before you build the image (`az acr build` in the deploy steps). This is the simplest way with the Bicep in `infra/`.
- **Or point `PRICING_FILE` at a file** in the container, for example a Container Apps secret mounted as a volume. The file replaces the built-in rates; it is not merged with them.

A file that is not valid JSON, or has a negative rate, stops the service at startup, so a typo cannot silently zero your costs. Check your provider's current prices; the built-in numbers are examples.

## Configuration reference

The service reads these environment variables. The Bicep in `infra/` sets them for you.

| Variable | Required | Meaning |
| --- | --- | --- |
| `AUTH_MODE` | yes | How `POST /events` is authenticated: `entra`, `key`, `entra,key` or `none`. No default. |
| `ENTRA_TENANT_ID` | with `entra` | Tenant that issues the tokens. |
| `ENTRA_AUDIENCE` | with `entra` | Comma-separated accepted audiences: the API app's application ID URI (`api://...`) and its client id. |
| `ENTRA_ALLOWED_PRINCIPALS` | no | Object ids or client app ids allowed to write without the `Events.Write` role. |
| `METRICS_API_KEY` | with `key` | Shared key, at least 32 characters. |
| `COSMOS_ENDPOINT` | yes | Cosmos DB account endpoint, such as `https://<account>.documents.azure.com:443/`. |
| `COSMOS_DATABASE` | yes | Database name, such as `AIMetrics`. |
| `COSMOS_CONTAINER` | yes | Container name, such as `Events`. Partition key `/tenantId` then `/featureName`. |
| `COSMOS_KEY` | no | Account key. Leave it unset to sign in with Entra (managed identity in Azure, Azure CLI locally); the identity needs the Cosmos DB Built-in Data Contributor role. The account in `infra/` disables keys. |
| `AZURE_CLIENT_ID` | no | Client id of a user-assigned managed identity to sign in to Cosmos DB with. |
| `PRICING_FILE` | no | Path to a pricing file that replaces the built-in rates. |
| `ALLOWED_ORIGINS` | no | Comma-separated browser origins allowed to call the API from another site. Empty means same-origin only. |
| `PORT` | no | Listen port, default `8080`. |

## Run it locally

You need Go (the version in [`metrics/go.mod`](../metrics/go.mod)) and a Cosmos DB account you can reach: your own account with `COSMOS_KEY`, or one where your Azure CLI sign-in has the data role.

```bash
cd metrics
az login        # skip if you set COSMOS_KEY
export COSMOS_ENDPOINT=https://<account>.documents.azure.com:443/
export COSMOS_DATABASE=AIMetrics
export COSMOS_CONTAINER=Events
export AUTH_MODE=none   # local only
go run .
```

Then send an event with `scripts/send-event-curl.sh` and open <http://localhost:8080/dashboard?feature=ai-code-review>. The tests need no Cosmos account: `go test ./...` runs against an in-memory fake.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| The service exits at startup naming `AUTH_MODE` | `AUTH_MODE` is unset or unknown, or a setting its mode needs is missing. | Set `AUTH_MODE`, and `ENTRA_TENANT_ID` and `ENTRA_AUDIENCE` for `entra`, or a 32+ character `METRICS_API_KEY` for `key`. |
| The stage warns `Failed to send AI Code Review metrics event: ... 401` | No credential, the wrong key, or a token for the wrong audience. | Check `metricsAuth` matches `AUTH_MODE`, `aiMetricsApiResource` matches `ENTRA_AUDIENCE`, or the key matches. |
| `... 403` | The token is valid but the identity lacks `Events.Write`. | Run `infra/grant-events-write.sh --principal <client id>` for the service connection. New role assignments can take a few minutes to reach new tokens. |
| `... 413` | The event is over 64 KB. | Should not happen with the stage's event; check custom senders. |
| No event and no warning | `metricsVariableGroup` is empty or the group has no `aiMetricsApiUrl`. | The log says `Metrics are not configured`; set the group. |
| The dashboard shows runs but $0 cost | The `modelName` is not in the pricing file. | Add your deployment name to the [pricing file](#pricing-file). |
| The browser gets a sign-in loop or `401` on the dashboard | You are not assigned to the dashboard app. | Assign your user or group to the `<prefix>-metrics-dashboard` enterprise application, or rerun `setup-entra.sh --dashboard-group <group object id>`. |
| `GET /metrics/summary` returns `502` | The service cannot read Cosmos DB. | Check the app's identity has the Cosmos DB Built-in Data Contributor role and the endpoint, database and container names. The log has the Cosmos error. |
