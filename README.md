# Keycloak Scripts

This can be futher extended for particular use cases in future. 
Originally written in JS (module files, extension `mjs`, developed and tested on `node v18`).
`tenantOnboarding.sh` is a bash port of `tenantOnboarding.mjs` with no Node/JS dependency -
see [Tenant onboarding (bash)](#tenant-onboarding-bash) below.

###### Maintainer
Name: Rohan Sawant

Email: rohan.sawant@zconsolutions.com


## Usage

## Tenant onboarding (node)
```bash 
node tenantOnboarding.mjs --realm=<REALM_NAME> --client='rehab-tracker-resource-server' --secret=<CLIENT_SECRET> --url='http://localhost:8080/auth' --tenant_name=<TENANT_NAME> --new_tenant_admin_name=<TENANT_ADMIN_NAME> --tenant_admin_email=<TENANT_ADMIN_EMAIL> --tenant_admin_password=<TENANT_ADMIN_PASSWORD>
```

## Tenant onboarding (bash)

`tenantOnboarding.sh` does everything `tenantOnboarding.mjs` does (creates the tenant's
Keycloak parent group, subgroups, role mappings, and admin user), **and** also runs the
task-list migration that previously required a manual
`curl -X POST .../new-tenant` call against the app — as direct SQL against the app
database instead, so no HTTP call (or running app instance) is needed to onboard a tenant.

It has no Node/JS dependency. Per-environment config (realm, client id/secret,
Keycloak URL, app DB host/user/name) is read from `.env`, one set of keys per
environment — nothing sensitive from there ends up on argv. The DB password and
everything specific to this particular onboarding run (tenant name, admin details,
...) are still interactive prompts, never stored. The master/template tenant task
lists get cloned from is the same one across every environment, so its id is
hardcoded in the script rather than configured per environment.

### Prerequisites

- `bash`, `curl`, `jq`, `uuidgen`, `psql` all available on `PATH`
- Network access to both the Keycloak admin API and the app's Postgres database
- The Keycloak client used must have `client_credentials` grant + service account roles
  sufficient to manage groups/roles/users in the target realm
- Copy [`.env.dist`](./.env.dist) to `.env` and fill in the `UAT_`/`DEV_`/`PROD_`/`LOCAL_`
  block(s) you plan to use — `REALM`, `CLIENT_ID`, `CLIENT_SECRET`, `KEYCLOAK_URL`,
  `DBHOST`, `DBPORT` (optional, defaults to `5432`), `DBUSER`, `DB`. `.env` is
  gitignored; the DB password is intentionally **not** one of these keys — it's
  always prompted at runtime instead.

### Usage

```bash
./tenantOnboarding.sh [uat|dev|prod|local]
```

Pass the environment as the first argument, or omit it to be prompted. Everything else
needed for that environment comes from `.env`; you're then prompted only for the new
tenant name, the tenant admin's full name/email/password, the new task list name
(defaults to `MASTER`), and the app DB password.

### Task list migration

After the Keycloak side is set up, the script runs the equivalent of the old
`POST /new-tenant` call (`newTenantMigration()` in `trinitiy-habitat-express/src/service/tenantManagementService.js`) as one
SQL transaction against the app database, cloning the master/template tenant's task
list (`110d61ca-2bbd-42f9-b6a4-4935396cddf5`, hardcoded — see above) into the new
tenant:

1. **New task list** — one row in `task_list_name` for the new tenant.
2. **Clone task groups** — every non-deleted `task_group` belonging to the master
   tenant is cloned under the new tenant, pointed at the new task list.
3. **Clone tasks** — every non-deleted `task` under those groups is cloned the same
   way, re-parented to the corresponding new group, marked `is_master = true`.
4. **Link into the task list** — one `task_and_task_list_name` row per cloned task.

Two temp tables carry the old-id → new-id mapping from step 2 into steps 3/4 and are
dropped automatically when the transaction commits.

**Failure behavior:** the migration is one transaction (`ON_ERROR_STOP=1`), so if any
step fails, nothing commits — you never end up with a half-cloned task list. This is
*more* atomic than the original `/new-tenant` endpoint, which has no transaction of its
own. That atomicity is scoped to the SQL step only, though — it does **not** extend
back to the Keycloak steps earlier in the script (parent group, subgroups, role
mappings, admin user), each of which is committed by Keycloak the moment it succeeds.
If the SQL migration fails after those steps already ran, you're left with a real
Keycloak tenant + admin user but no task list, and the script won't undo the Keycloak
side for you — re-running it will create a second Keycloak group for the same tenant
name (with a new random id) rather than resuming the first one.

### Running on Windows

Not directly — it's a bash script and relies on bash-only syntax (arrays, `[[ ]]`,
`printf -v`, here-strings), so it won't run under `cmd.exe` or plain PowerShell as-is.
You need an actual bash environment. Two options:

#### Option A: WSL (recommended)

Everything the script needs is a package install away:

```bash
wsl --install                                     # if WSL isn't set up yet, from PowerShell (admin)
# inside the WSL distro (e.g. Ubuntu):
sudo apt update && sudo apt install -y jq postgresql-client uuid-runtime
```

`curl`, `uuidgen` (from `uuid-runtime`), and `bash` come with most distros already;
the command above just fills in `jq` and `psql`. Then run it exactly as on Linux/macOS:

```bash
cd /mnt/c/path/to/keycloak-scripts   # your Windows drive, mounted under /mnt
./tenantOnboarding.sh
```

#### Option B: Git Bash

Git Bash bundles `bash` and `curl`, but not `jq`, `psql`, or `uuidgen` — you have to add
those yourself:

- `jq`: download `jq-win64.exe` from the [jq releases page](https://github.com/jqlang/jq/releases),
  rename it to `jq.exe`, and put it on `PATH` (e.g. in `C:\Program Files\Git\usr\bin`)
- `psql`: install the [PostgreSQL client tools](https://www.postgresql.org/download/windows/)
  (or just `psql.exe` from a full Postgres install) and add its `bin` folder to `PATH`
- `uuidgen`: Git Bash doesn't ship this and there's no official Windows build — either
  install it via [MSYS2](https://www.msys2.org/) (`pacman -S util-linux`), or swap the
  script's two `uuidgen` calls for `powershell.exe -Command "[guid]::NewGuid().ToString()"`

Given the extra manual setup Git Bash needs, WSL is the less error-prone path.


