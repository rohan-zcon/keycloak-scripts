#!/usr/bin/env bash
#
# Onboards a new tenant end-to-end:
#   1. Creates the tenant's Keycloak parent group + subgroups + role mappings + admin user
#      (bash port of tenantOnboarding.mjs).
#   2. Runs the task-list migration that used to require a manual
#      `curl -X POST .../new-tenant` call against this app, as direct SQL against the
#      app database, so no HTTP hop (and no app deploy) is required to onboard a tenant.
#
# Requires: bash 4+, curl, jq, uuidgen, psql
#
# Per-environment config (realm, client id/secret, keycloak url, db host/user/name)
# comes from ./.env - copy .env.dist to .env and fill it in, one set of keys per
# <ENV>_ prefix (UAT_/DEV_/PROD_/LOCAL_). Only the DB password and the values specific
# to this onboarding run (tenant name, admin details, ...) are prompted for.
#
# Usage: ./tenantOnboarding.sh [uat|dev|prod|local]
#   Environment can be passed as $1; if omitted, you'll be prompted for it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

for bin in curl jq uuidgen psql; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required dependency: $bin" >&2; exit 1; }
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
  [[ -n "$__value" ]] || { echo "${__label} is required" >&2; exit 1; }
  printf -v "$__var" '%s' "$__value"
}

prompt_secret() {
  local __var="$1" __label="$2"
  local __value
  read -rsp "${__label}: " __value
  echo
  [[ -n "$__value" ]] || { echo "${__label} is required" >&2; exit 1; }
  printf -v "$__var" '%s' "$__value"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Minimal, dependency-free .env loader (avoids `source`-ing an arbitrary file). Skips
# blank lines/comments, trims whitespace, strips one layer of surrounding quotes.
load_env_file() {
  local file="$1" line key value
  [[ -f "$file" ]] || { echo "Env file not found: $file (copy .env.dist to .env and fill it in)" >&2; exit 1; }
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
  *) echo "Unknown environment '${ENVIRONMENT}', expected one of: uat, dev, prod, local" >&2; exit 1 ;;
esac
ENV_PREFIX="$(tr '[:lower:]' '[:upper:]' <<<"$ENVIRONMENT")"

# Pulls "${ENV_PREFIX}_${2}" out of the environment (as loaded from .env) into $1.
preset() {
  local __var="$1" __suffix="$2" __key="${ENV_PREFIX}_${2}"
  printf -v "$__var" '%s' "${!__key:-}"
}

# var_name:env_suffix pairs - env_suffix matches this folder's existing DBHOST/DBUSER/DB
# naming (from db.js/index.mjs) rather than introducing a second convention
REQUIRED_PRESETS=(
  "REALM:REALM"
  "CLIENT_ID:CLIENT_ID"
  "CLIENT_SECRET:CLIENT_SECRET"
  "KEYCLOAK_URL:KEYCLOAK_URL"
  "DB_HOST:DBHOST"
  "DB_USER:DBUSER"
  "DB_NAME:DB"
)

# Shared across every environment - the master/template tenant task lists are cloned
# from, not something operators pick per run.
MASTER_TENANT_ID="110d61ca-2bbd-42f9-b6a4-4935396cddf5"

MISSING=()
for pair in "${REQUIRED_PRESETS[@]}"; do
  var_name="${pair%%:*}"
  env_suffix="${pair##*:}"
  preset "$var_name" "$env_suffix"
  [[ -n "${!var_name}" ]] || MISSING+=("${ENV_PREFIX}_${env_suffix}")
done
preset DB_PORT "DBPORT"
DB_PORT="${DB_PORT:-5432}"

if [[ "${#MISSING[@]}" -gt 0 ]]; then
  echo "Missing config in ${ENV_FILE} for environment '${ENVIRONMENT}':" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi

echo "== New tenant details (${ENVIRONMENT}) =="
prompt TENANT_NAME "New tenant name"
prompt ADMIN_NAME "New tenant admin full name (first last)"
prompt ADMIN_EMAIL "New tenant admin email"
prompt_secret ADMIN_PASSWORD "New tenant admin password"
prompt LIST_NAME "New task list name" "MASTER"

echo
prompt_secret DB_PASSWORD "DB password (${DB_USER}@${DB_HOST}/${DB_NAME})"

NEW_TENANT_ID="$(uuidgen)"
BASE_TENANT_NAME="Tenant:${TENANT_NAME}:${NEW_TENANT_ID}"

# Runs a Keycloak admin API call and prints its response body on stdout. On a non-2xx
# response it prints the method/url/status plus whatever error body Keycloak returned
# and exits - plain `curl -sf` was used before, but -s also swallows curl's own
# diagnostics on failure (not just the progress meter), so a failing call produced
# zero output anywhere and the script just stopped with no explanation.
kc_request() {
  local method="$1" url="$2" data="${3:-}" raw status body
  if [[ -n "$data" ]]; then
    raw="$(curl -s -w $'\n%{http_code}' -X "$method" "${AUTH_HEADER[@]}" "$url" -d "$data")"
  else
    raw="$(curl -s -w $'\n%{http_code}' -X "$method" "${AUTH_HEADER[@]}" "$url")"
  fi
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  if [[ ! "$status" =~ ^2 ]]; then
    echo "Keycloak API call failed: ${method} ${url} -> HTTP ${status}" >&2
    [[ -n "$body" ]] && echo "$body" >&2
    exit 1
  fi
  printf '%s' "$body"
}

echo
echo "Authenticating with Keycloak..."
TOKEN_RAW="$(curl -s -w $'\n%{http_code}' --request POST "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}")"
TOKEN_STATUS="${TOKEN_RAW##*$'\n'}"
TOKEN_BODY="${TOKEN_RAW%$'\n'*}"

if [[ ! "$TOKEN_STATUS" =~ ^2 ]]; then
  echo "Failed to authenticate with Keycloak -> HTTP ${TOKEN_STATUS}" >&2
  [[ -n "$TOKEN_BODY" ]] && echo "$TOKEN_BODY" >&2
  exit 1
fi
TOKEN="$(jq -r '.access_token' <<<"$TOKEN_BODY")"

AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

echo "Creating parent group '${BASE_TENANT_NAME}'..."
PARENT_PAYLOAD="$(jq -n --arg name "$BASE_TENANT_NAME" \
  '{name: $name, path: ("/" + $name), realmRoles: [], subGroups: [],
    access: {view: true, manage: true, manageMembership: true}}')"

kc_request POST "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" "$PARENT_PAYLOAD" >/dev/null

PARENT_GROUP_ID="$(kc_request GET "${KEYCLOAK_URL}/admin/realms/${REALM}/groups" \
  | jq -r --arg name "$BASE_TENANT_NAME" '.[] | select(.name == $name) | .id')"

if [[ -z "$PARENT_GROUP_ID" ]]; then
  echo "Could not find newly created parent group '${BASE_TENANT_NAME}'" >&2
  exit 1
fi
echo "Parent group id: ${PARENT_GROUP_ID}"

echo "Fetching realm roles..."
ALL_ROLES="$(kc_request GET "${KEYCLOAK_URL}/admin/realms/${REALM}/roles")"

# name:realmRole pairs, ported from subgroup.js
SUBGROUPS=(
  "tenant_admins:tenant_admin"
  "marketing:marketing"
  "project_admins:project_admin"
  "compliance_audiators:compliance_audiator"
  "account_managers:account_manager"
  "project_managers:project_manager"
)

for entry in "${SUBGROUPS[@]}"; do
  sub_name="${entry%%:*}"
  role_name="${entry##*:}"
  sub_path="/${BASE_TENANT_NAME}/${sub_name}"

  echo "Creating subgroup '${sub_name}'..."
  sub_payload="$(jq -n --arg name "$sub_name" --arg path "$sub_path" \
    '{name: $name, path: $path, subGroups: [],
      access: {view: true, manage: true, manageMembership: true}}')"

  kc_request POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups/${PARENT_GROUP_ID}/children" \
    "$sub_payload" >/dev/null

  # GET .../groups/{id}/children isn't implemented on every Keycloak version (some
  # only wire up POST on that sub-resource) - fetching the parent group's own
  # representation and reading its embedded subGroups works everywhere.
  sub_id="$(kc_request GET \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups/${PARENT_GROUP_ID}" \
    | jq -r --arg name "$sub_name" '.subGroups[]? | select(.name == $name) | .id')"

  if [[ -z "$sub_id" ]]; then
    echo "Could not find newly created subgroup '${sub_name}'" >&2
    exit 1
  fi

  role_json="$(jq -c --arg name "$role_name" '.[] | select(.name == $name)' <<<"$ALL_ROLES")"
  if [[ -z "$role_json" ]]; then
    echo "Realm role '${role_name}' not found" >&2
    exit 1
  fi

  echo "Mapping role '${role_name}' to subgroup '${sub_name}'..."
  kc_request POST \
    "${KEYCLOAK_URL}/admin/realms/${REALM}/groups/${sub_id}/role-mappings/realm" \
    "[${role_json}]" >/dev/null
done

# Matches tenantOnboarding.mjs's createUser(): only the first two space-separated
# words of the full name are used, any middle/extra names are dropped.
read -ra NAME_PARTS <<<"$ADMIN_NAME"
FIRST_NAME="${NAME_PARTS[0]:-}"
LAST_NAME="${NAME_PARTS[1]:-}"

echo "Creating tenant admin user '${ADMIN_EMAIL}'..."
USER_PAYLOAD="$(jq -n \
  --arg first "$FIRST_NAME" --arg last "$LAST_NAME" --arg email "$ADMIN_EMAIL" \
  --arg group "/${BASE_TENANT_NAME}/tenant_admins" --arg pw "$ADMIN_PASSWORD" \
  '{firstName: $first, lastName: $last, email: $email, enabled: true,
    groups: [$group],
    credentials: [{type: "password", temporary: false, value: $pw}],
    realmRoles: ["tenant_admin"]}')"

kc_request POST "${KEYCLOAK_URL}/admin/realms/${REALM}/users" "$USER_PAYLOAD" >/dev/null

echo "Keycloak onboarding done for tenant '${TENANT_NAME}' (${NEW_TENANT_ID})"

echo
echo "Migrating master tenant's task list into the new tenant..."

NEW_TASK_LIST_ID="$(uuidgen)"

export PGPASSWORD="$DB_PASSWORD"
trap 'unset PGPASSWORD' EXIT

# Replicates POST /new-tenant -> newTenantMigration() in
# src/service/tenantManagementService.js, run directly against the app DB instead of
# through the HTTP endpoint. Wrapped in one transaction so any failure leaves no partial
# data behind, unlike the original endpoint which has no such transaction and can
# partially apply on failure.
psql -v ON_ERROR_STOP=1 \
  -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
  -v new_tenant_id="$NEW_TENANT_ID" \
  -v master_tenant_id="$MASTER_TENANT_ID" \
  -v list_name="$LIST_NAME" \
  -v new_task_list_id="$NEW_TASK_LIST_ID" \
  <<'SQL'
BEGIN;

CREATE TEMP TABLE tmp_group_map (old_group_id uuid, new_group_id uuid) ON COMMIT DROP;
CREATE TEMP TABLE tmp_task_map (old_task_id uuid, new_task_id uuid) ON COMMIT DROP;

-- 1. new task list, referred to as MASTER for now (mirrors the code comment in
--    newTenantMigration)
INSERT INTO task_list_name (id, tenant_id, list_name, revision_date, is_finalized, created_at, updated_at)
VALUES (:'new_task_list_id', :'new_tenant_id', :'list_name', CURRENT_DATE, true, now(), now());

-- 2. clone the master tenant's task groups, keeping an old->new id mapping so tasks
--    can be re-parented below
INSERT INTO tmp_group_map (old_group_id, new_group_id)
SELECT id, gen_random_uuid()
FROM task_group
WHERE tenant_id = :'master_tenant_id' AND deleted_at IS NULL;

INSERT INTO task_group (id, tenant_id, title, task_list_name_id, created_at, updated_at)
SELECT m.new_group_id, :'new_tenant_id', tg.title, :'new_task_list_id', now(), now()
FROM task_group tg
JOIN tmp_group_map m ON tg.id = m.old_group_id;

-- 3. clone every task under those groups, marked is_master = true like the app does
INSERT INTO tmp_task_map (old_task_id, new_task_id)
SELECT t.id, gen_random_uuid()
FROM task t
JOIN tmp_group_map m ON t.task_group_id = m.old_group_id
WHERE t.deleted_at IS NULL;

INSERT INTO task (id, tenant_id, task_group_id, title, description, unit, quantity_type, price, price_type, is_master, created_at, updated_at)
SELECT tm.new_task_id, :'new_tenant_id', m.new_group_id, t.title, t.description, t.unit, t.quantity_type, t.price, t.price_type, true, now(), now()
FROM task t
JOIN tmp_group_map m ON t.task_group_id = m.old_group_id
JOIN tmp_task_map tm ON t.id = tm.old_task_id
WHERE t.deleted_at IS NULL;

-- 4. associate the cloned tasks with the new task list
INSERT INTO task_and_task_list_name (id, task_id, task_list_name_id, created_at, updated_at)
SELECT gen_random_uuid(), tm.new_task_id, :'new_task_list_id', now(), now()
FROM tmp_task_map tm;

COMMIT;
SQL

GROUP_COUNT="$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atq \
  -v new_tenant_id="$NEW_TENANT_ID" \
  -c "SELECT count(*) FROM task_group WHERE tenant_id = :'new_tenant_id';" 2>/dev/null || echo '?')"
TASK_COUNT="$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atq \
  -v new_tenant_id="$NEW_TENANT_ID" \
  -c "SELECT count(*) FROM task WHERE tenant_id = :'new_tenant_id';" 2>/dev/null || echo '?')"

unset PGPASSWORD
trap - EXIT

echo
echo "--------DONE--------"
echo "Tenant name:        ${TENANT_NAME}"
echo "New tenant id:       ${NEW_TENANT_ID}"
echo "Keycloak group path: /${BASE_TENANT_NAME}"
echo "Task groups cloned:  ${GROUP_COUNT}"
echo "Tasks cloned:        ${TASK_COUNT}"
