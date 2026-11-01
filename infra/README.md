# Metrics infrastructure

Bicep and two `az` scripts that deploy the PullPicket metrics API and dashboard to Azure, locked down by default:

- **Cosmos DB** (serverless, NoSQL): database `AIMetrics`, container `Events`, partition key `/tenantId` then `/featureName`. Key auth is disabled; only Entra identities with a data-plane role can read or write.
- **Container Registry** (Basic): holds the `pullpicket-metrics` image. No admin user, no anonymous pull.
- **Managed identity** (user-assigned): the app runs as it. It has `AcrPull` on the registry and the Cosmos DB Built-in Data Contributor role on the account.
- **Container Apps** (Consumption) with Log Analytics: the app on HTTPS, scaling to zero when idle.
- **Container Apps sign-in** with Entra in front of the dashboard and `/metrics/*`. Only users or groups you assign can sign in. `/events` and `/healthz` are excluded so pipelines can reach them; `/events` checks its own credential.
- **Two Entra app registrations**, made by [`setup-entra.sh`](setup-entra.sh) because Bicep cannot create them: the API (with the `Events.Write` app role pipelines need) and the dashboard sign-in app.

| File | What it does |
| --- | --- |
| [`main.bicep`](main.bicep) | Everything in one resource group. Without `imageTag` it skips the Container App. |
| [`main.bicepparam`](main.bicepparam) | Example parameters. The image tag and Entra values come from environment variables. |
| [`modules/`](modules) | `cosmos`, `registry`, `identity` (identity and its role grants), `environment`, `containerapp` (app and sign-in). |
| [`setup-entra.sh`](setup-entra.sh) | Creates or updates the two app registrations and writes their IDs and the dashboard secret to `.env.entra`. |
| [`grant-events-write.sh`](grant-events-write.sh) | Gives a pipeline's service connection the `Events.Write` role. |

## Before you start

- Azure CLI 2.60 or later, signed in (`az login`), plus `jq` and `bash`. Azure Cloud Shell has all three.
- The resource providers registered on the subscription. A new subscription often has none of them yet, and the deployment then fails with "not registered":

  ```bash
  for p in Microsoft.App Microsoft.OperationalInsights Microsoft.DocumentDB Microsoft.ContainerRegistry Microsoft.ManagedIdentity; do az provider register --namespace $p; done
  ```
- On the resource group: **Owner**, or **Contributor** plus **Role Based Access Control Administrator**, because the deployment creates role assignments.
- In Entra: rights to create app registrations and assign users to them (the default for members in most tenants, or **Application Administrator**).
- Docker is optional: `az acr build` builds the image in Azure.

## Deploy

Run these from the repository root. Replace the placeholders `<rg>` and `<region>`.

**1. Create the resource group and the base resources.** With no image tag the deployment creates Cosmos DB, the registry, the identity and the Container Apps environment, but not the app yet. It also prints the URL the app will get.

```bash
az group create --name <rg> --location <region>
az deployment group create --resource-group <rg> --parameters infra/main.bicepparam \
  --query properties.outputs --output json
```

Note the `registryName` and `metricsUrl` outputs.

**2. Register the Entra apps.** Pass `metricsUrl` so the dashboard's sign-in redirect points at the app. By default you are assigned to the dashboard; add `--dashboard-group <group object id>` to let a group in instead.

```bash
infra/setup-entra.sh --app-url <metricsUrl>
```

The script writes `.env.entra` (mode 600, ignored by git) with the API's client ID and application ID URI, the dashboard's client ID and the dashboard client secret. It is safe to rerun; it only adds a new secret when it creates the dashboard app or you pass `--rotate-secret`.

**3. Build and push the image.**

```bash
export PULLPICKET_IMAGE_TAG="$(git rev-parse --short HEAD)"
az acr build --registry <registryName> --image "pullpicket-metrics:$PULLPICKET_IMAGE_TAG" metrics
```

If your subscription cannot run ACR Tasks, build locally and push instead: `az acr login --name <registryName>`, then `docker build` and `docker push` to `<registryName>.azurecr.io/pullpicket-metrics:$PULLPICKET_IMAGE_TAG`.

**4. Deploy the app.** `main.bicepparam` reads the tag and the Entra values from the environment, so nothing secret goes on the command line or into a file in the repository.

```bash
source .env.entra
az deployment group create --resource-group <rg> --parameters infra/main.bicepparam \
  --query properties.outputs.metricsUrl.value --output tsv
```

Then delete `.env.entra`, or move it somewhere safe; you only need it again to redeploy without rotating the secret.

**5. Let the pipeline send metrics.** Find the application (client) ID of the Azure DevOps service connection the review stage uses (Project settings, Service connections, the connection, Manage App registration or Manage service principal), then:

```bash
infra/grant-events-write.sh --principal <service connection client id>
```

**6. Point the pipeline at the API.** Create a variable group, pass its name as `metricsVariableGroup` in the stage, and add:

| Variable | Value |
| --- | --- |
| `aiMetricsApiUrl` | `metricsUrl` |
| `aiMetricsApiResource` | the API's application ID URI (`PULLPICKET_API_APP_ID_URI` in `.env.entra`). It is `api://pullpicket-metrics` unless the tenant only allows URIs on a verified domain; `setup-entra.sh` then uses `api://<API client id>` and says so. |

**7. Check it.** Open `<metricsUrl>/` in a browser: you should be sent to the Microsoft sign-in page, then see the landing page. Without a credential, `POST /events` answers `401`:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "<metricsUrl>/events" -H 'Content-Type: application/json' -d '{}'
```

After the next pull request review, the run appears on `<metricsUrl>/dashboard?feature=ai-code-review`.

## Outputs

| Output | Meaning |
| --- | --- |
| `metricsUrl` | Public URL of the API and dashboard. Known from step 1. |
| `containerAppName` | Container App name, `<namePrefix>-metrics`. |
| `registryName`, `registryLoginServer` | Registry for `az acr build`; the image is `<registryLoginServer>/pullpicket-metrics:<tag>`. |
| `cosmosEndpoint`, `cosmosDatabaseName`, `cosmosContainerName`, `cosmosAccountId` | The store, for running the API elsewhere or for queries. |

## Options

Set these in `main.bicepparam` or with `--parameters name=value`.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `namePrefix` | `pullpicket` | Prefix for resource names, 3 to 20 characters. |
| `authMode` | `entra` | `AUTH_MODE` for `POST /events`: `entra`, `key` or `entra,key`. |
| `metricsApiKey` | empty | Shared key for `key` or `entra,key`, at least 32 characters (`openssl rand -base64 32`), stored as a Container Apps secret. Pass it from an environment variable, not in the file. |
| `entraAllowedPrincipals` | empty | Object or client IDs allowed to write without the `Events.Write` role. |
| `entraTenantId` | this tenant | Tenant that issues the API's tokens and the dashboard sign-ins. |
| `minReplicas`, `maxReplicas` | `0`, `2` | Scale. With `0` the first request after an idle spell waits a few seconds while a replica starts. |
| `location` | resource group's region | Region for every resource. |

To ship a new version, build with a new tag (step 3) and repeat step 4.

## Teardown

```bash
az group delete --name <rg>
source .env.entra   # or look the IDs up with: az ad app list --display-name pullpicket-metrics
az ad app delete --id "$PULLPICKET_DASHBOARD_CLIENT_ID"
az ad app delete --id "$PULLPICKET_API_CLIENT_ID"
```

Deleting the resource group removes the stored events. The Cosmos account keeps 7 days of continuous backup until the account itself is deleted. Deleted app registrations stay restorable for 30 days under Entra ID, App registrations, Deleted applications.
