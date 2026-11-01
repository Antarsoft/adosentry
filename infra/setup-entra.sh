#!/usr/bin/env bash
# Creates or updates the two Microsoft Entra app registrations the metrics
# service needs (decision D8: an az CLI script, because Bicep cannot create
# app registrations):
#
#   <prefix>-metrics-api        the API that senders get tokens for. It defines
#                               the Events.Write app role; POST /events accepts
#                               only tokens that carry it.
#   <prefix>-metrics-dashboard  the sign-in app for Container Apps
#                               authentication in front of the dashboard. Only
#                               users or groups assigned to it can sign in.
#
# Safe to rerun: existing registrations are found by name and updated.
#
# Usage:
#   infra/setup-entra.sh --app-url https://<app>.<environment-domain> [options]
#
# Options:
#   --app-url URL          the metricsUrl output of the first deployment (required)
#   --name-prefix NAME     prefix for the registrations' names (default: pullpicket)
#   --api-app-id-uri URI   application ID URI for the API (default: api://<prefix>-metrics;
#                          falls back to api://<client id> if the tenant refuses it)
#   --dashboard-group ID   object id of a group allowed to open the dashboard
#                          (default: the signed-in user)
#   --rotate-secret        add a new client secret for the dashboard app even if one
#                          is already recorded in the output file
#   --out FILE             where to write the results (default: .env.entra, mode 600)
#
# The output file holds export lines that infra/main.bicepparam reads,
# including the dashboard client secret. Keep it out of source control
# (.env.* is git-ignored) and delete it once the app is deployed.
#
# Needs: az (signed in to the target tenant, with rights to create app
# registrations) and jq.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

die() { echo "setup-entra: $*" >&2; exit 1; }

app_url=""
name_prefix="pullpicket"
api_app_id_uri=""
dashboard_group=""
rotate_secret=false
out_file=".env.entra"

while [ $# -gt 0 ]; do
  case "$1" in
    --app-url) app_url="${2:-}"; shift 2 ;;
    --name-prefix) name_prefix="${2:-}"; shift 2 ;;
    --api-app-id-uri) api_app_id_uri="${2:-}"; shift 2 ;;
    --dashboard-group) dashboard_group="${2:-}"; shift 2 ;;
    --rotate-secret) rotate_secret=true; shift ;;
    --out) out_file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -n "$app_url" ] || die "--app-url is required: use the metricsUrl output of the first deployment."
app_url="${app_url%/}"
case "$app_url" in
  https://*) ;;
  *) die "--app-url must start with https://" ;;
esac
[ -n "$name_prefix" ] || die "--name-prefix must not be empty."
[ -n "$out_file" ] || die "--out must not be empty."
command -v az >/dev/null || die "the Azure CLI (az) is required."
command -v jq >/dev/null || die "jq is required."

graph="https://graph.microsoft.com/v1.0"
api_name="${name_prefix}-metrics-api"
dashboard_name="${name_prefix}-metrics-dashboard"
api_app_id_uri="${api_app_id_uri:-api://${name_prefix}-metrics}"
# Container Apps sign-in uses the empty (default) app role when a user or
# group is assigned to an app that defines no roles of its own.
default_access_role="00000000-0000-0000-0000-000000000000"

new_uuid() {
  if command -v uuidgen >/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    die "cannot generate a UUID: install uuidgen."
  fi
}

# Prints the appId of the single app registration with this display name,
# or nothing. Fails if the name is ambiguous.
find_app() {
  local ids count
  ids="$(az ad app list --display-name "$1" --query '[].appId' --output tsv)"
  count="$(printf '%s' "$ids" | grep -c . || true)"
  [ "$count" -le 1 ] || die "$count app registrations are named '$1'; delete the extras or use --name-prefix."
  printf '%s' "$ids"
}

# Prints the object id of the app's service principal, creating it if needed.
ensure_sp() {
  local id
  id="$(az ad sp list --filter "appId eq '$1'" --query '[0].id' --output tsv)"
  if [ -z "$id" ]; then
    id="$(az ad sp create --id "$1" --query id --output tsv)"
  fi
  printf '%s' "$id"
}

tenant_id="$(az account show --query tenantId --output tsv)"
[ -n "$tenant_id" ] || die "not signed in: run az login --tenant <tenant> first."
echo "Tenant: $tenant_id"

# --- API app registration ----------------------------------------------------

api_client_id="$(find_app "$api_name")"
if [ -z "$api_client_id" ]; then
  echo "Creating app registration $api_name"
  api_client_id="$(az ad app create --display-name "$api_name" --sign-in-audience AzureADMyOrg \
    --query appId --output tsv)"
else
  echo "Found app registration $api_name ($api_client_id)"
fi

# Events.Write: an application role, so only service principals (the
# pipeline's service connection) can hold it, never users.
roles="$(az ad app show --id "$api_client_id" --query appRoles --output json)"
if [ "$(jq '[.[] | select(.value == "Events.Write")] | length' <<<"$roles")" -eq 0 ]; then
  echo "Adding the Events.Write app role"
  roles_file="$(mktemp)"
  trap 'rm -f "$roles_file"' EXIT
  jq --arg id "$(new_uuid)" '. + [{
      allowedMemberTypes: ["Application"],
      description: "Send review metrics events to POST /events.",
      displayName: "Events.Write",
      id: $id,
      isEnabled: true,
      value: "Events.Write"
    }]' <<<"$roles" >"$roles_file"
  az ad app update --id "$api_client_id" --app-roles "@$roles_file"
fi

current_uri="$(az ad app show --id "$api_client_id" --query 'identifierUris[0]' --output tsv)"
if [ -n "$current_uri" ]; then
  api_app_id_uri="$current_uri"
else
  echo "Setting the application ID URI to $api_app_id_uri"
  if ! az ad app update --id "$api_client_id" --identifier-uris "$api_app_id_uri" 2>/dev/null; then
    # Some tenants only allow api://<client id> or a verified domain.
    api_app_id_uri="api://$api_client_id"
    echo "The tenant refused it; using $api_app_id_uri instead"
    az ad app update --id "$api_client_id" --identifier-uris "$api_app_id_uri"
  fi
fi

ensure_sp "$api_client_id" >/dev/null

# --- Dashboard app registration ----------------------------------------------

redirect_uri="$app_url/.auth/login/aad/callback"
dashboard_client_id="$(find_app "$dashboard_name")"
dashboard_created=false
if [ -z "$dashboard_client_id" ]; then
  echo "Creating app registration $dashboard_name"
  dashboard_client_id="$(az ad app create --display-name "$dashboard_name" --sign-in-audience AzureADMyOrg \
    --web-redirect-uris "$redirect_uri" --enable-id-token-issuance true \
    --query appId --output tsv)"
  dashboard_created=true
else
  echo "Found app registration $dashboard_name ($dashboard_client_id); setting its redirect URI"
  az ad app update --id "$dashboard_client_id" --web-redirect-uris "$redirect_uri" --enable-id-token-issuance true
fi

dashboard_sp="$(ensure_sp "$dashboard_client_id")"
# Only assigned users and groups may sign in to the dashboard.
az ad sp update --id "$dashboard_sp" --set appRoleAssignmentRequired=true

if [ -n "$dashboard_group" ]; then
  principal="$dashboard_group"
  principal_label="group $dashboard_group"
else
  principal="$(az ad signed-in-user show --query id --output tsv 2>/dev/null || true)"
  principal_label="you ($principal)"
fi
if [ -z "$principal" ]; then
  echo "WARNING: signed in as a service principal, so nobody was given dashboard access." >&2
  echo "         Rerun with --dashboard-group <group object id>." >&2
else
  assigned="$(az rest --method get --url "$graph/servicePrincipals/$dashboard_sp/appRoleAssignedTo" \
    --query "length(value[?principalId=='$principal'])" --output tsv)"
  if [ "$assigned" = "0" ]; then
    echo "Allowing $principal_label to open the dashboard"
    az rest --method post --url "$graph/servicePrincipals/$dashboard_sp/appRoleAssignedTo" \
      --headers 'Content-Type=application/json' \
      --body "{\"principalId\":\"$principal\",\"resourceId\":\"$dashboard_sp\",\"appRoleId\":\"$default_access_role\"}" \
      --output none
  else
    echo "$principal_label can already open the dashboard"
  fi
fi

# Container Apps sign-in needs a client secret for the dashboard app. Keep the
# one already recorded in the output file unless asked to rotate it.
dashboard_secret=""
if [ "$rotate_secret" = false ] && [ "$dashboard_created" = false ] && [ -f "$out_file" ]; then
  dashboard_secret="$(sed -n "s/^export PULLPICKET_DASHBOARD_CLIENT_SECRET='\(.*\)'$/\1/p" "$out_file")"
fi
if [ -z "$dashboard_secret" ]; then
  echo "Adding a client secret to $dashboard_name (valid for 1 year)"
  dashboard_secret="$(az ad app credential reset --id "$dashboard_client_id" --append \
    --display-name container-apps-auth --years 1 --query password --output tsv)"
fi

# --- Results -------------------------------------------------------------------

(
  umask 077
  cat >"$out_file" <<EOF
# Written by infra/setup-entra.sh. Holds a secret: do not commit, delete after deploying.
export PULLPICKET_TENANT_ID='$tenant_id'
export PULLPICKET_API_CLIENT_ID='$api_client_id'
export PULLPICKET_API_APP_ID_URI='$api_app_id_uri'
export PULLPICKET_DASHBOARD_CLIENT_ID='$dashboard_client_id'
export PULLPICKET_DASHBOARD_CLIENT_SECRET='$dashboard_secret'
EOF
)

cat <<EOF

Done. Values written to $out_file (load them with: source $out_file)

  Tenant                     $tenant_id
  API client id              $api_client_id
  API application ID URI     $api_app_id_uri
  Dashboard client id        $dashboard_client_id
  Dashboard redirect URI     $redirect_uri

For the pipeline's metrics variable group:
  aiMetricsApiUrl            $app_url
  aiMetricsApiResource       $api_app_id_uri

Next: give the pipeline's service connection the Events.Write role with
  infra/grant-events-write.sh --principal <service connection app id>
EOF
