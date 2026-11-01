#!/usr/bin/env bash
# Sender-agnostic by design: this is the entire integration surface. Any
# language/tool that can make an HTTP POST can emit metrics -- no SDK, no
# client library, no per-language wrapper required.

AI_METRICS_API_URL="${AI_METRICS_API_URL:-http://localhost:8080}"

curl -X POST "$AI_METRICS_API_URL/events" \
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

# "tenantId" is optional and defaults to "default"; a single-tenant deployment
# can leave it out. It takes letters, digits, ".", "_" and "-" (64 at most).
#
# Note everything under "custom" is completely free-form -- a different AI
# feature (say, a PR summarizer, or a triage bot with no concept of a
# "repository") just sends whatever fields make sense for it. Nothing to
# register, declare, or migrate.
