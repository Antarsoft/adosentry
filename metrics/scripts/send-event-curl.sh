#!/usr/bin/env bash
# Sender-agnostic by design: this is the entire integration surface. Any
# language/tool that can make an HTTP POST can emit metrics -- no SDK, no
# client library, no per-language wrapper required.
#
# POST /events needs a credential (see AUTH_MODE on the server). Set one of:
#
#   AI_METRICS_API_KEY   the server's METRICS_API_KEY (AUTH_MODE key or entra,key);
#                        sent as X-Api-Key
#   AI_METRICS_TOKEN     an Entra access token for the API (AUTH_MODE entra or
#                        entra,key); sent as Authorization: Bearer
#   AI_METRICS_RESOURCE  instead of a token: the API's application ID URI
#                        (api://...); the script asks the Azure CLI for a token.
#                        The signed-in identity needs the Events.Write app role.
#
# With none of them set the request goes out without a credential, which only
# a server running AUTH_MODE=none (local development) accepts.
set -euo pipefail

AI_METRICS_API_URL="${AI_METRICS_API_URL:-http://localhost:8080}"

auth_header=()
if [ -n "${AI_METRICS_API_KEY:-}" ]; then
  auth_header=(-H "X-Api-Key: $AI_METRICS_API_KEY")
else
  token="${AI_METRICS_TOKEN:-}"
  if [ -z "$token" ] && [ -n "${AI_METRICS_RESOURCE:-}" ]; then
    token="$(az account get-access-token --resource "$AI_METRICS_RESOURCE" --query accessToken --output tsv)"
  fi
  if [ -n "$token" ]; then
    auth_header=(-H "Authorization: Bearer $token")
  fi
fi

curl --fail-with-body -sS -X POST "$AI_METRICS_API_URL/events" \
  "${auth_header[@]}" \
  -H "Content-Type: application/json" \
  -d '{
    "featureName": "ai-code-review",
    "tenantId": "default",
    "source": "ado-pipeline",
    "custom": {
      "repository": "my-repo",
      "prId": "1234",
      "pipelineRunId": "5678",
      "outcome": "commented",
      "commentsCount": 4,
      "filesReviewed": 12,
      "latencyMs": 8300,
      "model": "gpt-5-mini"
    }
  }'
echo

# "tenantId" is optional and defaults to "default"; a single-tenant deployment
# can leave it out. It takes letters, digits, ".", "_" and "-" (64 at most).
#
# Note everything under "custom" is completely free-form -- a different AI
# feature (say, a PR summarizer, or a triage bot with no concept of a
# "repository") just sends whatever fields make sense for it. Nothing to
# register, declare, or migrate.
