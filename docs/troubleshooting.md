# Troubleshooting

Start with the log of the **Run AI Code Review** step. Every run ends with a one-line summary (outcome, files, batches, comments, tokens and model time), and every failure names the call that failed and its HTTP status. The sections below cover the problems that come up most often on a first setup.

- [The stage is skipped](#the-stage-is-skipped)
- [No comments appear, and the log warns "Failed to post comment"](#no-comments-appear-and-the-log-warns-failed-to-post-comment)
- [The model call fails with 401 or 403](#the-model-call-fails-with-401-or-403)
- [The model call fails with 404, or the token is for the wrong resource](#the-model-call-fails-with-404-or-the-token-is-for-the-wrong-resource)
- [A setting has the wrong value, or the agent pool overrides it](#a-setting-has-the-wrong-value-or-the-agent-pool-overrides-it)
- [Other errors](#other-errors)

## The stage is skipped

The PullPicket stage runs only when `Build.Reason` is `PullRequest`. On a CI push, a manual run or a scheduled run it shows as skipped, by design: there is no pull request to comment on.

To get pull request runs:

- Add the pipeline as a **build validation** policy on the target branch (Repos > Branches > *branch* > Branch policies > Build validation). Azure Repos ignores the YAML `pr:` trigger; only the branch policy queues runs with `Build.Reason` set to `PullRequest`.
- To re-run a review, queue the build again from the pull request (the **Checks** panel), not from the pipeline page. A run queued from the pipeline page is a manual run, and the stage is skipped.

If the stage is skipped on a pull request run, check that the stages before it succeeded: the stage condition is `and(succeeded(), ...)`, so a failed build stage skips the review.

## No comments appear, and the log warns "Failed to post comment"

The model answered, but Azure DevOps refused the comments. You will usually see these lines in the log:

```
WARNING: Failed to acquire access token, continuing without review history: ...
WARNING: Failed to retrieve existing threads, continuing without review history: ...
WARNING: Failed to post comment on '/src/app.ts' line 12: ...
```

Reading history and posting are best-effort, so the step can still finish green with outcome `no-comments`. The cause is almost always the service connection's identity:

1. **The identity is not a member of the Azure DevOps organisation.** A service principal or managed identity is not added to the organisation just because it has an Azure role. Add it under Organization settings > Users > Add users (search for the service connection's app registration name or managed identity name), with at least the Basic access level. On Azure DevOps Server, add the identity to the collection instead.
2. **The identity cannot contribute to pull requests.** In Project settings > Repositories > *repository* > Security, give the identity (or a group it belongs to, such as the project's Contributors) **Contribute to pull requests**. The project's build service account is a different identity; granting it does not help.
3. **The organisation blocks the identity's tenant.** If the organisation is connected to a Microsoft Entra tenant, the service connection must be in that tenant.

To find the identity, open the service connection (Project settings > Service connections), choose **Manage Service Principal** or **Manage App registration**, and note its display name and application (client) id.

If adding the identity fails with `Given email address '<name>' is invalid`, the organisation is not connected to a Microsoft Entra tenant, so Azure DevOps cannot look up service principals. Connect it under Organization settings > Microsoft Entra to the tenant that holds the service connection, sign out and back in, and pick the identity from the search suggestions.

## The model call fails with 401 or 403

```
LLM API call failed for batch 1 of 1 (status: 401, attempt 1 of ...)
Failed to call LLM API at https://<resource>.openai.azure.com/... (status: 403)
```

With `foundryAuth: entra` (the default), the review signs in to the model with the service connection's identity. That identity needs the **Cognitive Services OpenAI User** role (or Cognitive Services User, or Azure AI User for Foundry projects) on the model's resource:

```bash
az role assignment create \
  --assignee <service-connection-client-id> \
  --role "Cognitive Services OpenAI User" \
  --scope /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.CognitiveServices/accounts/<resource-name>
```

Role assignments can take several minutes to apply. The Contributor or Owner role on the resource is not enough on its own: they manage the resource but do not grant data-plane access to the model.

Other causes of `401` and `403`:

- **The resource has key auth only.** If `disableLocalAuth` is off and you prefer the key, set `foundryAuth: key` and add `foundry-key` (secret) to the model variable group.
- **The network blocks the agent.** A resource with public network access disabled or limited to selected networks returns `403` to a Microsoft-hosted agent. Use a self-hosted agent inside the allowed network, or add its address range.
- **`foundryAuth: key` with a wrong key.** The key must belong to the same resource as `modelDeploymentUrl`.

## The model call fails with 404, or the token is for the wrong resource

The Entra token is requested for `foundryTokenResource`, which defaults to `https://ai.azure.com` for Azure AI Foundry. A classic **Azure OpenAI** resource (an endpoint such as `https://<resource>.openai.azure.com/`) expects a token for Cognitive Services instead. If you see `401` with an audience or "invalid token" message on such a resource, set:

```yaml
parameters:
  foundryTokenResource: 'https://cognitiveservices.azure.com'
```

A `404` usually means `modelDeploymentUrl` is wrong. It must be the full chat completions URL with the deployment name and an `api-version` the deployment supports, such as `https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=<version>`. Copy it from the deployment's page in the Foundry portal rather than building it by hand.

## A setting has the wrong value, or the agent pool overrides it

The review reads `modelName`, `modelDeploymentUrl`, `reasoningEffort` and `aiReviewDebugLogging` as pipeline variables from the model variable group, which the template links at stage level. Check:

- **The variable is missing.** Azure Pipelines leaves an undefined `$(name)` macro as literal text, so a missing `modelDeploymentUrl` shows up as a call to `$(modelDeploymentUrl)` (an invalid URI), and a missing `modelName` as a model called `$(modelName)`. Check the spelling of the variable names and of `modelVariableGroup`, and that the pipeline is allowed to use the group (Pipelines > Library > *group* > Pipeline permissions).
- **Queue-time values.** A variable marked "Let users override this value when running this pipeline" can be changed for a single run, and that value wins.
- **Several groups define the same name.** When groups linked at the same level define the same variable, the group listed last wins. Keep the model settings in one group.

The log line `Response from <modelName> received ...` shows the model name the run actually used.

**Self-hosted agent pools** add their own causes:

- The agent needs PowerShell 7 (`pwsh`), the Az PowerShell modules (the `AzurePowerShell@5` task with `azurePowerShellVersion: LatestVersion` uses what is installed), `git` and `bash` on the path. Microsoft-hosted `ubuntu-latest` and `windows-latest` images have all of them.
- Proxy settings on the agent (`HTTPS_PROXY`, `NO_PROXY`, or the agent's `.proxy` file) apply to the model and Azure DevOps calls. A proxy that intercepts TLS can make the model call fail even though the role and URL are right.
- An agent that runs as a different user may pick up an older Az module or a cached Azure sign-in from that user's profile. Check the Az.Accounts version the task prints at the start of the step.

To compare, run the same pipeline once on a Microsoft-hosted pool (`pool: vmImage: ubuntu-latest`).

## Other errors

| Log message | Cause | Fix |
| --- | --- | --- |
| `The repository pullpicket in project <project> could not be retrieved` | The `name:` of the `templates` repository resource does not match the imported repository. A new project's default repository is named after the project. | Set `name: <project>/<repository>` to the repository you imported into. |
| `promptMode is 'rules' but the base prompt file was not found` | The PullPicket repository was not checked out as `templates`. | Name the repository resource `templates` (see the quick start). |
| `No model API key was provided and AuthMode is not entra` | `foundryAuth: key` without a `foundry-key` value. | Add `foundry-key` as a secret variable in the model variable group, or use `foundryAuth: entra`. |
| `... was truncated (finish_reason: length)` | The model ran out of output tokens on a large batch. | Lower `reviewMaxFilesPerBatch` or `reviewMaxBatchTokens`, or lower `reasoningEffort`. |
| `... was blocked by the content filter` | The Azure content filter blocked the response. | Review the filter settings on the deployment; the rest of the batches still post. |
| `Failed to parse LLM review output as JSON` | The model does not support structured output (`response_format` with a JSON schema). | Use a model that does. |
| `No reviewable files remain after path filtering` | Every changed file matched an exclude, or none matched `reviewPathSpec`. | Check `reviewPathSpec`, `reviewExcludePathSpec` and `reviewDefaultExcludes`. |
| `metricsAuth is 'entra' but aiMetricsApiResource ... is not set` | The metrics variable group has no `aiMetricsApiResource`. | Set it to the metrics API's application ID URI, or set `metricsAuth: key`. See [metrics.md](metrics.md). |
| `Failed to send AI Code Review metrics event: ... 401` or `403` | The metrics API rejected the credential. | `401`: wrong or missing token or key. `403`: the identity lacks the `Events.Write` role; run `infra/grant-events-write.sh`. See [metrics.md](metrics.md#troubleshooting). |

A failed metrics event is only a warning: it never fails the review. To see exactly what was sent to the model for one run, set the `aiReviewDebugLogging` parameter to `'true'`; the full diff is then written to the log, so turn it off again afterwards.
