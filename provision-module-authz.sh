#!/bin/bash
set -euo pipefail

# Provisions the Keycloak Authorization Services objects for a new resource-server
# module, against ONE realm:
#   - 4 scopes:           create:<module>, read:<module>, update:<module>, delete:<module>
#   - 1 resource:          rehab-tracker-service:<module> (carries the 4 scopes above)
#   - 1 scope-permission:  manage_<module> (resource + scopes + whichever existing
#                          policies you pick interactively when it's created)
#
# Generic version of the one-off donation-module provisioning script (Feature #240 /
# task #350) - same shape (rehab-tracker-service:<module> resource, manage_<module>
# permission), but the module name is now an input instead of hardcoded, and the
# policies to attach are chosen interactively from whatever policies already exist in
# the realm instead of being copied from a specific other permission.
#
# Idempotent: safe to re-run. Existing scopes/resource/permission are left untouched
# and just resolved to their ids. If the permission already exists, the interactive
# policy picker is skipped entirely (its policies are only set at creation time).
#
# Requires: bash, curl, jq
#
# Per-environment config (realm, resource-server client id, Keycloak URL, the
# realm-admin username to authenticate as) comes from ./.env, same file and same
# <ENV>_ prefix convention (UAT_/DEV_/PROD_/LOCAL_) as tenantOnboarding.sh - copy
# .env.dist to .env and fill it in if you haven't already. The admin password and the
# module name are the only things prompted for at runtime; the admin password is never
# stored in .env, same reasoning as tenantOnboarding.sh's DB password.
#
# Usage: ./provision-module-authz.sh [uat|dev|prod|local] [module_name]
#   Both can be passed positionally; either one left off is prompted for instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

log() { echo "[provision-module-authz] $*" >&2; }

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { log "Missing required dependency: $bin"; exit 1; }
done

prompt() {
  local __var="$1" __label="$2" __default="${3:-}"
  local __value
  if [[ -n "$__default" ]]; then
    read -rp "${__label} [${__default}]: " __value
    __value="${__value:-$__default}"
  else
    read -rp "${__label}: " __value
  fi
  [[ -n "$__value" ]] || { log "${__label} is required"; exit 1; }
  printf -v "$__var" '%s' "$__value"
}

prompt_secret() {
  local __var="$1" __label="$2"
  local __value
  # Typed in plain, same as tenantOnboarding.sh's password prompts - one-off
  # interactive run, not worth the UX hit of hidden input.
  read -rp "${__label}: " __value
  [[ -n "$__value" ]] || { log "${__label} is required"; exit 1; }
  printf -v "$__var" '%s' "$__value"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Lowercases, replaces anything that isn't a-z/0-9 with a single underscore, and
# trims leading/trailing underscores - "Loan Applications" -> "loan_applications",
# "donations" -> "donations".
slugify() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')"
  printf '%s' "$s"
}

# Minimal, dependency-free .env loader (avoids `source`-ing an arbitrary file) - same
# as tenantOnboarding.sh's. Skips blank lines/comments, trims whitespace, strips one
# layer of surrounding quotes.
load_env_file() {
  local file="$1" line key value
  [[ -f "$file" ]] || { log "Env file not found: $file (copy .env.dist to .env and fill it in)"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *"="* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
      value="${value:1:-1}"
    fi
    export "$key=$value"
  done < "$file"
}

load_env_file "$ENV_FILE"

ENVIRONMENT="${1:-}"
if [[ -z "$ENVIRONMENT" ]]; then
  prompt ENVIRONMENT "Environment (uat/dev/prod/local)"
fi
ENVIRONMENT="$(tr '[:upper:]' '[:lower:]' <<<"$ENVIRONMENT")"
case "$ENVIRONMENT" in
  uat|dev|prod|local) ;;
  *) log "Unknown environment '${ENVIRONMENT}', expected one of: uat, dev, prod, local"; exit 1 ;;
esac
ENV_PREFIX="$(tr '[:lower:]' '[:upper:]' <<<"$ENVIRONMENT")"

# Pulls "${ENV_PREFIX}_${2}" out of the environment (as loaded from .env) into $1.
preset() {
  local __var="$1" __suffix="$2" __key="${ENV_PREFIX}_${2}"
  printf -v "$__var" '%s' "${!__key:-}"
}

# var_name:env_suffix pairs - RESOURCE_SERVER_CLIENT_ID reuses the same CLIENT_ID key
# tenantOnboarding.sh uses, since both scripts target the same resource-server client.
REQUIRED_PRESETS=(
  "REALM:REALM"
  "KEYCLOAK_URL:KEYCLOAK_URL"
  "RESOURCE_SERVER_CLIENT_ID:CLIENT_ID"
  "ADMIN_USERNAME:ADMIN_USERNAME"
)

MISSING=()
for pair in "${REQUIRED_PRESETS[@]}"; do
  var_name="${pair%%:*}"
  env_suffix="${pair##*:}"
  preset "$var_name" "$env_suffix"
  [[ -n "${!var_name}" ]] || MISSING+=("${ENV_PREFIX}_${env_suffix}")
done

if [[ "${#MISSING[@]}" -gt 0 ]]; then
  log "Missing config in ${ENV_FILE} for environment '${ENVIRONMENT}':"
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi

# Rarely differs per environment - override via env var only if yours does.
ADMIN_REALM="${ADMIN_REALM:-master}"
ADMIN_CLIENT_ID="${ADMIN_CLIENT_ID:-admin-cli}"

# The 4 CRUD actions every module gets a scope for - fixed shape, only the module
# name varies. Edit this list (and nowhere else) if a module ever needs a
# different action set.
ACTIONS=(create read update delete)

# --- Module name -------------------------------------------------------------

MODULE_NAME_RAW="${2:-}"
if [[ -z "${MODULE_NAME_RAW}" ]]; then
  prompt MODULE_NAME_RAW "Module name (e.g. donations)"
fi
MODULE_NAME_RAW="$(trim "${MODULE_NAME_RAW}")"
MODULE_SLUG="$(slugify "${MODULE_NAME_RAW}")"

if [[ -z "${MODULE_SLUG}" ]]; then
  log "ERROR: module name must contain at least one letter or digit."
  exit 1
fi
if [[ "${MODULE_SLUG}" != "${MODULE_NAME_RAW}" ]]; then
  log "Normalized module name '${MODULE_NAME_RAW}' -> '${MODULE_SLUG}'."
fi

SCOPE_NAMES=()
for action in "${ACTIONS[@]}"; do
  SCOPE_NAMES+=("${action}:${MODULE_SLUG}")
done
RESOURCE_NAME="rehab-tracker-service:${MODULE_SLUG}"
PERMISSION_NAME="manage_${MODULE_SLUG}"

log "Provisioning module '${MODULE_SLUG}' in '${ENVIRONMENT}' (scopes: ${SCOPE_NAMES[*]}; resource: ${RESOURCE_NAME}; permission: ${PERMISSION_NAME})"

echo
prompt_secret ADMIN_PASSWORD "Keycloak admin password (${ADMIN_USERNAME}@${ADMIN_REALM})"

log "Authenticating as realm-admin '${ADMIN_USERNAME}' against realm '${ADMIN_REALM}'..."
ADMIN_TOKEN=$(curl -sf -X POST \
  "${KEYCLOAK_URL}/realms/${ADMIN_REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${ADMIN_CLIENT_ID}" \
  -d "username=${ADMIN_USERNAME}" \
  -d "password=${ADMIN_PASSWORD}" | jq -r '.access_token')

if [[ -z "${ADMIN_TOKEN}" || "${ADMIN_TOKEN}" == "null" ]]; then
  log "ERROR: failed to obtain admin token. Check credentials/URL/realm."
  exit 1
fi

AUTH_HEADER=(-H "Authorization: Bearer ${ADMIN_TOKEN}" -H "Content-Type: application/json")
BASE="${KEYCLOAK_URL}/admin/realms/${REALM}"

log "Resolving internal client id for '${RESOURCE_SERVER_CLIENT_ID}'..."
CLIENT_UUID=$(curl -sf "${AUTH_HEADER[@]}" \
  "${BASE}/clients?clientId=${RESOURCE_SERVER_CLIENT_ID}" | jq -r '.[0].id')

if [[ -z "${CLIENT_UUID}" || "${CLIENT_UUID}" == "null" ]]; then
  log "ERROR: client '${RESOURCE_SERVER_CLIENT_ID}' not found in realm '${REALM}'."
  exit 1
fi
log "Resource server client uuid: ${CLIENT_UUID}"

AUTHZ="${BASE}/clients/${CLIENT_UUID}/authz/resource-server"

# --- 1. Scopes -------------------------------------------------------------

declare -A SCOPE_IDS
for scope_name in "${SCOPE_NAMES[@]}"; do
  existing_id=$(curl -sf "${AUTH_HEADER[@]}" "${AUTHZ}/scope?name=${scope_name}" | jq -r '.[0].id // empty')
  if [[ -n "${existing_id}" ]]; then
    log "Scope '${scope_name}' already exists (${existing_id}), skipping create."
    SCOPE_IDS["${scope_name}"]="${existing_id}"
  else
    log "Creating scope '${scope_name}'..."
    created_id=$(curl -sf -X POST "${AUTH_HEADER[@]}" "${AUTHZ}/scope" \
      -d "$(jq -n --arg name "${scope_name}" '{name: $name}')" | jq -r '.id')
    SCOPE_IDS["${scope_name}"]="${created_id}"
  fi
done

# --- 2. Resource ------------------------------------------------------------

RESOURCE_ID=$(curl -sf "${AUTH_HEADER[@]}" "${AUTHZ}/resource?name=${RESOURCE_NAME}" | jq -r '.[0]._id // .[0].id // empty')
if [[ -n "${RESOURCE_ID}" ]]; then
  log "Resource '${RESOURCE_NAME}' already exists (${RESOURCE_ID}), skipping create."
else
  log "Creating resource '${RESOURCE_NAME}' with scopes: ${SCOPE_NAMES[*]}..."
  scopes_json=$(printf '%s\n' "${SCOPE_NAMES[@]}" | jq -R '{name: .}' | jq -s '.')
  RESOURCE_ID=$(curl -sf -X POST "${AUTH_HEADER[@]}" "${AUTHZ}/resource" \
    -d "$(jq -n --arg name "${RESOURCE_NAME}" --argjson scopes "${scopes_json}" \
      '{name: $name, displayName: $name, scopes: $scopes}')" | jq -r '._id // .id')
fi
log "Resource id: ${RESOURCE_ID}"

# --- 3. Scope-permission -----------------------------------------------------

EXISTING_PERMISSION_ID=$(curl -sf "${AUTH_HEADER[@]}" "${AUTHZ}/permission/scope?name=${PERMISSION_NAME}" | jq -r '.[0].id // empty')

if [[ -n "${EXISTING_PERMISSION_ID}" ]]; then
  log "Permission '${PERMISSION_NAME}' already exists (${EXISTING_PERMISSION_ID}), skipping create."
  log "NOTE: not updating its resources/scopes/policies -- delete it first in the KC console if it needs to be re-synced."
  log "Done. '${MODULE_SLUG}' resource/scopes/permission are provisioned in realm '${REALM}' at ${KEYCLOAK_URL}."
  exit 0
fi

# Only real policies (role/js/time/aggregate/... - not other permissions) are valid
# choices here, same restriction the Keycloak console's own "Apply Policy" picker
# applies when creating a scope-permission.
log "Fetching existing policies from realm '${REALM}'..."
POLICIES_JSON=$(curl -sf "${AUTH_HEADER[@]}" "${AUTHZ}/policy?permission=false&max=-1")
POLICY_COUNT=$(jq 'length' <<<"${POLICIES_JSON}")

SELECTED_POLICY_IDS=()
SELECTED_POLICY_NAMES=()

if [[ "${POLICY_COUNT}" -eq 0 ]]; then
  log "No policies exist yet in realm '${REALM}' - '${PERMISSION_NAME}' will be created with none attached."
  log "(With zero policies and decisionStrategy AFFIRMATIVE, Keycloak denies every request against it until you attach one.)"
else
  mapfile -t POLICY_ROWS < <(jq -r '.[] | "\(.name)\t\(.type)\t\(.id)"' <<<"${POLICIES_JSON}")

  echo >&2
  echo "Available policies in realm '${REALM}':" >&2
  for i in "${!POLICY_ROWS[@]}"; do
    IFS=$'\t' read -r p_name p_type _ <<<"${POLICY_ROWS[$i]}"
    printf '  %2d) %-40s (%s)\n' "$((i + 1))" "${p_name}" "${p_type}" >&2
  done

  while :; do
    read -rp $'\nSelect policies to attach to \''"${PERMISSION_NAME}"$'\' - space/comma-separated numbers, or "none": ' selection
    selection="$(trim "${selection}")"

    if [[ "$(printf '%s' "${selection}" | tr '[:upper:]' '[:lower:]')" == "none" ]]; then
      SELECTED_POLICY_IDS=()
      SELECTED_POLICY_NAMES=()
      break
    fi

    read -ra tokens <<<"${selection//,/ }"
    if [[ "${#tokens[@]}" -eq 0 ]]; then
      echo "Enter at least one number, or \"none\"." >&2
      continue
    fi

    valid=true
    picked_ids=()
    picked_names=()
    for tok in "${tokens[@]}"; do
      if ! [[ "${tok}" =~ ^[0-9]+$ ]] || ((tok < 1 || tok > ${#POLICY_ROWS[@]})); then
        echo "Invalid selection: '${tok}' (pick a number 1-${#POLICY_ROWS[@]})" >&2
        valid=false
        break
      fi
      IFS=$'\t' read -r p_name _ p_id <<<"${POLICY_ROWS[$((tok - 1))]}"
      picked_ids+=("${p_id}")
      picked_names+=("${p_name}")
    done

    "${valid}" && { SELECTED_POLICY_IDS=("${picked_ids[@]}"); SELECTED_POLICY_NAMES=("${picked_names[@]}"); break; }
  done

  if [[ "${#SELECTED_POLICY_NAMES[@]}" -gt 0 ]]; then
    log "Selected policies: $(
      IFS=', '
      echo "${SELECTED_POLICY_NAMES[*]}"
    )"
  else
    log "No policies selected - '${PERMISSION_NAME}' will be created with none attached."
  fi
fi

if [[ "${#SELECTED_POLICY_IDS[@]}" -gt 0 ]]; then
  policy_ids_json=$(printf '%s\n' "${SELECTED_POLICY_IDS[@]}" | jq -R . | jq -s .)
else
  policy_ids_json='[]'
fi
scope_ids_json=$(printf '%s\n' "${SCOPE_IDS[@]}" | jq -R . | jq -s .)

log "Creating scope-permission '${PERMISSION_NAME}'..."
curl -sf -X POST "${AUTH_HEADER[@]}" "${AUTHZ}/permission/scope" \
  -d "$(jq -n \
    --arg name "${PERMISSION_NAME}" \
    --arg desc "Manage ${MODULE_SLUG} records" \
    --argjson resources "$(jq -n --arg r "${RESOURCE_ID}" '[$r]')" \
    --argjson scopes "${scope_ids_json}" \
    --argjson policies "${policy_ids_json}" \
    '{
      name: $name,
      description: $desc,
      resources: $resources,
      scopes: $scopes,
      policies: $policies,
      decisionStrategy: "AFFIRMATIVE"
    }')" >/dev/null
log "Created '${PERMISSION_NAME}'."

log "Done. '${MODULE_SLUG}' resource/scopes/permission are provisioned in realm '${REALM}' at ${KEYCLOAK_URL}."
