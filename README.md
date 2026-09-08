# Keycloak Scripts

This can be futher extended for particular use cases in future.

Two independent scripts live here:

- [Tenant onboarding](#tenant-onboarding) (`tenantOnboarding.mjs` / `tenantOnboarding.sh`) —
  creates a new tenant's Keycloak group/subgroups/roles/admin user (and, for the bash
  version, its initial task list in the app DB).
- [Module authz provisioning](#module-authz-provisioning) (`provision-module-authz.sh`) —
  creates the Keycloak Authorization Services scopes/resource/permission for a new
  resource-server module (e.g. adding a `donations` module).

They don't depend on each other and can be run independently.

###### Maintainer
Name: Rohan Sawant

Email: rohan.sawant@zconsolutions.com


## Tenant onboarding

Originally written in JS (module files, extension `mjs`, developed and tested on
`node v18`). `tenantOnboarding.sh` is a bash port of `tenantOnboarding.mjs` with no
Node/JS dependency.

### [LEGACY] Node (`tenantOnboarding.mjs`)

```bash
node tenantOnboarding.mjs --realm=<REALM_NAME> --client='rehab-tracker-resource-server' --secret=<CLIENT_SECRET> --url='http://localhost:8080/auth' --tenant_name=<TENANT_NAME> --new_tenant_admin_name=<TENANT_ADMIN_NAME> --tenant_admin_email=<TENANT_ADMIN_EMAIL> --tenant_admin_password=<TENANT_ADMIN_PASSWORD>
```

### Bash (`tenantOnboarding.sh`)

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

#### Prerequisites

- `bash`, `curl`, `jq`, `uuidgen`, `psql` all available on `PATH`
- Network access to both the Keycloak admin API and the app's Postgres database
- The Keycloak client used must have `client_credentials` grant + service account roles
  sufficient to manage groups/roles/users in the target realm
- Copy [`.env.dist`](./.env.dist) to `.env` and fill in the `UAT_`/`DEV_`/`PROD_`/`LOCAL_`
  block(s) you plan to use — `REALM`, `CLIENT_ID`, `CLIENT_SECRET`, `KEYCLOAK_URL`,
  `DBHOST`, `DBPORT` (optional, defaults to `5432`), `DBUSER`, `DB`. `.env` is
  gitignored; the DB password is intentionally **not** one of these keys — it's
  always prompted at runtime instead.

#### Usage

```bash
./tenantOnboarding.sh [uat|dev|prod|local]
```

Pass the environment as the first argument, or omit it to be prompted. Everything else
needed for that environment comes from `.env`; you're then prompted only for the new
tenant name, the tenant admin's full name/email/password, the new task list name
(defaults to `MASTER`), and the app DB password.

Both password prompts (tenant admin password, DB password) echo what you type back to
the screen rather than masking it — deliberate, since this is a one-off interactive run
and not worth the UX hit of hidden input. Be mindful of shoulder-surfing/screen-sharing
when running it.

#### Task list migration

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

#### Running on Windows

Not directly — it's a bash script and relies on bash-only syntax (arrays, `[[ ]]`,
`printf -v`, here-strings), so it won't run under `cmd.exe` or plain PowerShell as-is.
You need an actual bash environment. Two options:

##### Option A: WSL

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

##### Option B: Git Bash

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


## Module authz provisioning

`provision-module-authz.sh` provisions the Keycloak Authorization Services objects for
a new resource-server module — e.g. adding a `donations` module to
`rehab-tracker-resource-server` — against one realm:

- **4 scopes**: `create:<module>`, `read:<module>`, `update:<module>`, `delete:<module>`
- **1 resource**: `rehab-tracker-service:<module>`, carrying those 4 scopes
- **1 scope-permission**: `manage_<module>`, tying the resource + scopes to whichever
  existing policies you pick interactively when it's first created

The module name is an input (positional arg or interactive prompt — see
[Usage](#usage-1) below) rather than hardcoded, so the same script provisions any
module. It's a generic version of a one-off script originally written just for a
`donations` module; the resource/permission naming shape (`rehab-tracker-service:<module>`,
`manage_<module>`) is unchanged from that original.

**Idempotent:** safe to re-run. Existing scopes/resource/permission are left untouched
and just resolved to their ids. If `manage_<module>` already exists, the whole policy
step (including the interactive picker) is skipped — its policies are only ever set at
creation time. To change which policies a module's permission uses, delete the
permission in the Keycloak console and re-run the script.

### Prerequisites

- `bash`, `curl`, `jq` available on `PATH` (no `uuidgen`/`psql` needed — this script
  only talks to the Keycloak admin API)
- Network access to the Keycloak admin API
- The admin user must be a realm-admin (or otherwise have
  `manage-authorization`/`manage-clients` rights) in `ADMIN_REALM` (default `master`),
  authenticated via the `admin-cli` public client's password grant
- The target client (`RESOURCE_SERVER_CLIENT_ID`, read from `.env`) must already exist
  in `REALM` with authorization services enabled
- Copy [`.env.dist`](./.env.dist) to `.env` and fill in the block(s) you plan to use —
  same file `tenantOnboarding.sh` reads. This script additionally needs
  `<ENV>_ADMIN_USERNAME` (the realm-admin username to authenticate as); its password
  is intentionally not a key here — always prompted at runtime, same reasoning as
  `tenantOnboarding.sh`'s DB password.
  **Note this script's auth is different from `tenantOnboarding.sh`'s:** `tenantOnboarding.sh`
  authenticates as the resource-server client itself, via `CLIENT_ID`/`CLIENT_SECRET`
  (client_credentials grant) — this script instead authenticates as a human
  realm-admin user (username/password grant), unrelated to `CLIENT_ID`/`CLIENT_SECRET`.
  The password it prompts for is whatever you'd type into the Keycloak Admin Console's
  own login screen (`<KEYCLOAK_URL>/admin/`) for `<ENV>_ADMIN_USERNAME` in that
  environment — not an API credential or client secret.
- At least one policy should already exist in the realm if you want the new
  permission to actually allow anyone through — see [Policy picker](#policy-picker)
  below for what happens if none exist yet

### Usage

```bash
./provision-module-authz.sh [uat|dev|prod|local] [module_name]
```

Pass the environment and/or module name positionally, or leave either off to be
prompted — same style as `tenantOnboarding.sh`. Everything else needed for that
environment (`REALM`, `KEYCLOAK_URL`, resource server client id, admin username) comes
from `.env`; you're then prompted for the admin password (visible as you type, same as
`tenantOnboarding.sh`'s prompts — see [that note](#bash-tenantonboardingsh) above).

```
$ ./provision-module-authz.sh
Environment (uat/dev/prod/local): local
Module name (e.g. donations): donations
[provision-module-authz] Provisioning module 'donations' in 'local' (scopes: create:donations read:donations update:donations delete:donations; resource: rehab-tracker-service:donations; permission: manage_donations)

Keycloak admin password (admin@master): admin
[provision-module-authz] Authenticating as realm-admin 'admin' against realm 'master'...
```

`RESOURCE_SERVER_CLIENT_ID` reuses the same `<ENV>_CLIENT_ID` value `tenantOnboarding.sh`
reads (it's the same client in both scripts); `ADMIN_REALM` (default `master`) and
`ADMIN_CLIENT_ID` (default `admin-cli`) rarely differ per environment, so they stay
plain env-var overrides rather than `.env` keys — set them in your shell if a given
environment's admin realm/client really is different.

The module name is normalized (lowercased, anything that isn't a letter/digit
collapsed to a single `_`) before use — `"Loan Applications"` becomes
`loan_applications`; the script logs the normalized form if it differs from what you
typed.

### Policy picker

When `manage_<module>` doesn't exist yet, the script fetches every policy already
defined in the realm (role/js/time/aggregate/... — not other permissions, same
restriction the Keycloak console's own "Apply Policy" picker applies) and prompts you
to choose which ones to attach, since there's no single "obvious" source to copy them
from once this isn't just the donations module anymore:

```
Available policies in realm 'rehab-tracker-prod':
   1) admin-role-policy                     (role)
   2) tenant-admin-policy                   (role)
   3) super-admin-policy                    (role)
   4) business-hours-policy                 (time)

Select policies to attach to 'manage_donations' - space/comma-separated numbers, or "none": 1 3
```

Enter one or more numbers (space- or comma-separated), or `none` to create the
permission with no policies attached. Invalid input (out-of-range number, empty input)
re-prompts rather than failing the run. If the realm has no policies defined at all,
the picker is skipped and the permission is created with none attached — the script
warns that, with `decisionStrategy: AFFIRMATIVE` and zero policies, Keycloak denies
every request against it until a policy is added later.

### Running on Windows

Lighter than the onboarding script's Windows story, since this one only needs `curl`
and `jq` (no `uuidgen`/`psql`) — but it's still a bash script (arrays, `[[ ]]`,
`mapfile`, here-strings), so it needs an actual bash environment same as above.

##### Option A: WSL

```bash
wsl --install          # if WSL isn't set up yet, from PowerShell (admin)
sudo apt update && sudo apt install -y jq
```

`curl` and `bash` come with most distros already. Then:

```bash
cd /mnt/c/path/to/keycloak-scripts
./provision-module-authz.sh donations
```

##### Option B: Git Bash

Git Bash bundles `bash` and `curl`; only `jq` needs adding — download `jq-win64.exe`
from the [jq releases page](https://github.com/jqlang/jq/releases), rename it to
`jq.exe`, and put it on `PATH` (e.g. in `C:\Program Files\Git\usr\bin`).
