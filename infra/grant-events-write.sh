#!/usr/bin/env bash
# Lets a pipeline send metrics: assigns the metrics API's Events.Write app
# role to the service principal behind an Azure DevOps service connection
# (or any other sender's identity). Safe to rerun.
#
# Usage:
#   infra/grant-events-write.sh --principal <app id or object id> [options]
#
# Options:
#   --principal ID       the sender's identity: the service connection's
#                        application (client) id, a managed identity's client id,
#                        or a service principal object id (required)
#   --api-client-id ID   the API app registration's client id (default:
#                        $PULLPICKET_API_CLIENT_ID from .env.entra, else looked up
#                        by name)
#   --name-prefix NAME   prefix used by setup-entra.sh (default: pullpicket)
#
# The same grant by hand, with the object ids of both service principals and
# the role's id:
#   az rest --method post \
#     --url https://graph.microsoft.com/v1.0/servicePrincipals/<sender sp id>/appRoleAssignments \
#     --body '{"principalId":"<sender sp id>","resourceId":"<api sp id>","appRoleId":"<Events.Write id>"}'
#
# Needs: az, signed in with rights to grant app roles on the API app (its
# owner, or Application Administrator).
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

die() { echo "grant-events-write: $*" >&2; exit 1; }

principal=""
api_client_id="${PULLPICKET_API_CLIENT_ID:-}"
name_prefix="pullpicket"

while [ $# -gt 0 ]; do
  case "$1" in
    --principal) principal="${2:-}"; shift 2 ;;
    --api-client-id) api_client_id="${2:-}"; shift 2 ;;
    --name-prefix) name_prefix="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$principal" ] || die "--principal is required (see --help)."
command -v az >/dev/null || die "the Azure CLI (az) is required."

graph="https://graph.microsoft.com/v1.0"

if [ -z "$api_client_id" ]; then
  api_client_id="$(az ad app list --display-name "${name_prefix}-metrics-api" --query '[].appId' --output tsv)"
  [ -n "$api_client_id" ] || die "no app registration named ${name_prefix}-metrics-api: run infra/setup-entra.sh first."
  [ "$(printf '%s\n' "$api_client_id" | grep -c .)" -eq 1 ] || die "more than one app registration is named ${name_prefix}-metrics-api; pass --api-client-id."
fi

api_sp="$(az ad sp show --id "$api_client_id" --query id --output tsv)" ||
  die "the API app $api_client_id has no service principal: run infra/setup-entra.sh."
role_id="$(az ad sp show --id "$api_client_id" --query "appRoles[?value=='Events.Write'].id | [0]" --output tsv)"
[ -n "$role_id" ] || die "the API app $api_client_id has no Events.Write role: run infra/setup-entra.sh."

sender_sp="$(az ad sp show --id "$principal" --query id --output tsv)" ||
  die "no service principal found for $principal. Use the service connection's application (client) id."
sender_name="$(az ad sp show --id "$sender_sp" --query displayName --output tsv)"

existing="$(az rest --method get --url "$graph/servicePrincipals/$sender_sp/appRoleAssignments" \
  --query "length(value[?resourceId=='$api_sp' && appRoleId=='$role_id'])" --output tsv)"
if [ "$existing" != "0" ]; then
  echo "$sender_name ($sender_sp) already has Events.Write."
  exit 0
fi

az rest --method post --url "$graph/servicePrincipals/$sender_sp/appRoleAssignments" \
  --headers 'Content-Type=application/json' \
  --body "{\"principalId\":\"$sender_sp\",\"resourceId\":\"$api_sp\",\"appRoleId\":\"$role_id\"}" \
  --output none
echo "Granted Events.Write to $sender_name ($sender_sp)."
echo "Tokens issued from now on carry the role; a token fetched earlier does not, so rerun the pipeline."
