# Migrating the Auth0 Tenant to Terraform (Code-First)

This guide walks through converting an **existing Auth0 tenant** — whose resources
were created manually in the dashboard — into **Terraform-managed code** inside
this repo. The strategy is:

1. **Export a starting point** with `auth0 terraform generate` (the CLI scans the
   live tenant and emits HCL + an `import` block per resource).
2. **Restructure** the generated files into this repo's module layout
   (`modules/auth0_demo/` shared logic, `envs/<env>/` per-environment roots).
3. **Import** the live resources into Terraform state so the code *adopts*
   (rather than recreates) everything that already exists.
4. **Wire credentials** into the CI/CD pipeline via GitHub secrets (never
   committed).
5. **Cutover**: prove a clean plan, apply, and retire the placeholder
   `null_resource`.

> ⚠️ The Auth0 Terraform provider can **read and manage** an existing tenant,
> but `auth0_tenant` **cannot be created** via the Management API. Since our
> tenant already exists, that limitation is not a problem — we only manage it.

---

## 0. Goals & principles (best practice)

- **Adopt, don't recreate.** The first apply must be a *no-op* (or near no-op)
  drift check. We import existing resources into state first so Terraform
  treats them as already-created.
- **No secrets in the repo.** All Auth0 credentials (client secret / API token)
  and the state password live in **GitHub secrets**, resolved at deploy time —
  the same pattern this repo already uses for `TF_HTTP_PASSWORD`.
- **Least privilege.** Use a **dedicated machine-to-machine (M2M) Auth0 client**
  with only the scopes Terraform needs, separate from any human login.
- **Deterministic, reviewable code.** Split the generated blob into
  logically-grouped `.tf` files, extract per-environment values into
  `variables.tf`/`terraform.tfvars`, and keep secrets out of `tfvars`.
- **One shared module.** All Auth0 logic lives in `modules/auth0_demo/`; each
  env root (`envs/dev|uat|prod`) just instantiates it with its own args.
- **Safe rollout.** Dev first → UAT → Prod, each behind the existing GitHub
  environment approval gates.

---

## 1. Prerequisites

| Item | Notes |
|------|-------|
| **Auth0 CLI** (`auth0`) | Recent version (the `auth0 terraform generate` command is experimental). `auth0 --version` to confirm. |
| **Terraform** `>= 1.7` | The workflow pins `1.9`. `terraform version` locally. |
| **An existing Auth0 tenant** | The one with manual resources. |
| **Auth0 API client (M2M)** | A dedicated application (see Step 2). |
| **Admin access** | To create the M2M client and grant scopes. |

---

## 2. Create a dedicated M2M API client for Terraform

This client is used by **both** the `auth0` CLI (export) and the `auth0`
Terraform provider (import/plan/apply). It is **not** a user-facing app.

1. In the Auth0 dashboard → **Applications → Create Application**.
   - Type: **Machine to Machine**.
   - Name: `terraform-managed` (or similar).
2. In **API Authorization**, select **Auth0 Management API** and add the scopes
   Terraform will need. For a full tenant takeover use **all** `read:*` and
   `update:*`/`create:*`/`delete:*` scopes you intend to manage. A practical
   starting set:
   - `read:clients`, `create:clients`, `update:clients`, `delete:clients`
   - `read:connections`, `create:connections`, `update:connections`, `delete:connections`
   - `read:resource_servers`, `create:resource_servers`, `update:resource_servers`, `delete:resource_servers`
   - `read:roles`, `create:roles`, `update:roles`, `delete:roles`
   - `read:organizations`, `create:organizations`, `update:organizations`, `delete:organizations`
   - `read:tenant_settings`, `update:tenant_settings`
   - `read:email_provider`, `update:email_provider`
   - `read:guardian`, `update:guardian`
   - `read:grants`, `create:grants`, `update:grants`, `delete:grants`
   - `read:actions`, `create:actions`, `update:actions`, `delete:actions`
   - `read:branding`, `update:branding`
   - `read:pages`, `update:pages`
   - `read:prompts`, `update:prompts`
   - `read:logs` (useful for debugging)

   > Add scopes conservatively at first; expand as you adopt more resource types.
3. Record the **Client ID**. The client **secret** is shown once — store it
   securely (password manager). It will go into GitHub secrets, not the repo.

> **Why a dedicated client?** It isolates Terraform's blast radius, is easy to
> rotate, and avoids coupling to a human account that may change password or
> lose MFA.

---

## 3. Configure the Auth0 CLI

The CLI authenticates against the tenant. For the export step you can use
either an M2M token (recommended, scriptable) or `auth0 login` (browser).

### 3a. Using M2M credentials (recommended)

```bash
export AUTH0_DOMAIN="<your-tenant>.auth0.com"
export AUTH0_CLIENT_ID="<terraform-managed client id>"
export AUTH0_CLIENT_SECRET="<client secret>"

# Verify:
auth0 tenants list
auth0 clients list
```

### 3b. Using browser login (one-off)

```bash
auth0 login
auth0 tenants use <your-tenant>.auth0.com
```

> The **provider** (Terraform) reads `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`,
> `AUTH0_CLIENT_SECRET` **or** `AUTH0_API_TOKEN`. The CLI export step requires
> the domain + client id/secret to be present so it can run `terraform`
> internally (see Step 4).

---

## 4. Export the initial code with `auth0 terraform generate`

This is the "get a starting point" step. The command scans the live tenant and
writes a small, self-contained Terraform root into an output directory:

- `auth0_main.tf` — `terraform` block + `provider "auth0" {}`.
- `auth0_import.tf` — one `import { id = "..." to = auth0_xxx.name }` block per
  discovered resource (this is what makes the import work).
- Then (if provider credentials are set) it runs `terraform init` and
  `terraform plan -generate-config-out=auth0_generated.tf`, producing
  **`auth0_generated.tf`** with the full HCL for every resource.

```bash
# Point the CLI at the tenant
export AUTH0_DOMAIN="<your-tenant>.auth0.com"
export AUTH0_CLIENT_ID="<terraform-managed client id>"
export AUTH0_CLIENT_SECRET="<client secret>"

# Generate into a scratch dir (NOT inside the repo yet)
auth0 terraform generate --output-dir tmp-auth0-tf --force
```

### What you'll have in `tmp-auth0-tf/`

```
tmp-auth0-tf/
├── auth0_main.tf        # terraform + provider block
├── auth0_import.tf      # import blocks (one per resource) — throwaway
└── auth0_generated.tf   # full HCL for all resources — your starting point
```

> **Notes**
> - `auth0 terraform generate` is **experimental** and may skip resources your
>   client lacks scope for (403 → warning + skip). If something is missing,
>   add the scope and re-run.
> - The generated `auth0_main.tf` pins the provider to
>   `>= 1.0.0, < 1.58.0`. We'll align that with the repo's pinned version later.
> - `-r / --resources` lets you export a subset, e.g.
>   `auth0 terraform generate -o tmp-auth0-tf -r auth0_client,auth0_tenant`.
>   Useful to start small and adopt incrementally.

### Review the generated HCL before moving it

Open `auth0_generated.tf` and sanity-check:
- Every dashboard resource you care about is present.
- Secret-looking values (client secrets, provider credentials) are **there in
  plain text** in the generated file — this is expected for an export, but these
  values must be **moved out** into variables/secret sources before the file
  lands in the repo (see Step 6).

---

## 5. Restructure into the repo's module layout

The repo convention is:

```
modules/auth0_demo/     # ALL shared Auth0 resource logic (main.tf, variables.tf, outputs.tf)
envs/dev/               # per-env root: backend.tf, main.tf, terraform.tfvars
envs/uat/
envs/prod/
```

So the generated single-file config is **split and moved** into the module.
Suggested file split inside `modules/auth0_demo/`:

```
modules/auth0_demo/
├── provider.tf            # required_providers (auth0) — no provider block w/ secrets here
├── tenant.tf              # auth0_tenant (+ auth0_pages, auth0_prompt, auth0_branding…)
├── clients.tf             # auth0_client / auth0_client_credentials
├── connections.tf         # auth0_connection / auth0_connection_clients
├── resource_servers.tf    # auth0_resource_server / auth0_resource_server_scopes
├── client_grants.tf       # auth0_client_grant
├── roles.tf               # auth0_role / auth0_role_permissions
├── organizations.tf       # auth0_organization (+ connections)
├── actions.tf             # auth0_action / auth0_trigger_actions
├── email.tf               # auth0_email_provider / auth0_email_template
├── guardian.tf            # auth0_guardian
├── variables.tf           # input variables (per-env values live here)
└── outputs.tf             # module outputs
```

> Keep the **resource addresses stable** when splitting files — moving a
> resource between files does **not** change its address
> (`auth0_client.web`), so state/import stays intact. Only the **name** in
> `resource "type" "NAME"` matters.

### 5a. Provider block

`modules/auth0_demo/provider.tf`:

```hcl
terraform {
  required_providers {
    auth0 = {
      source  = "auth0/auth0"
      version = ">= 1.0.0"   # align with the version you tested in Step 4
    }
  }
}
```

> **Do not put `provider "auth0" { client_secret = "..." }` in a committed
> file.** The provider reads `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`,
> `AUTH0_CLIENT_SECRET` / `AUTH0_API_TOKEN` from the environment (set by the
> GitHub secret at deploy time). If you prefer explicit config, read from
> `var.*` that is fed by a secret — never hardcode.

### 5b. Move resource blocks into the themed files

Copy each generated resource block from `tmp-auth0-tf/auth0_generated.tf` into
the matching module file above. At this stage the blocks can stay **mostly as
generated** — we parameterize in Step 6.

### 5c. Drop the placeholder

The current `modules/auth0_demo/main.tf` contains a `null_resource.hello_world`
placeholder and a commented-out `auth0_tenant`. **Remove the `null_resource`**
and the `null` provider requirement once real Auth0 resources are in place.
(Do this last, in Step 9, after import is proven — or now if you're confident.)

---

## 6. Parameterize & extract secrets (best practice)

The generated HCL has **hardcoded** values and **plaintext secrets**. Make it
reviewable and secret-free.

### 6a. Per-environment values → `variables.tf`

Identify values that differ per environment (or that you simply want to be
explicit) and promote them to module inputs. Example `modules/auth0_demo/variables.tf`:

```hcl
variable "tenant_friendly_name" {
  description = "Auth0 tenant friendly name"
  type        = string
}

variable "allowed_logout_urls" {
  description = "Allowed post-logout redirect URLs"
  type        = list(string)
  default     = []
}

variable "clients" {
  description = "Auth0 clients to manage"
  type = list(object({
    name            = string
    type            = string   # native / regular_web / spa / machine_to_machine
    callback_urls   = list(string)
    redirect_uris   = list(string)
    grant_types     = list(string)
  }))
  default = []
}

# ...etc. for each resource type you manage
```

Then reference them in the resource files:

```hcl
resource "auth0_tenant" "this" {
  friendly_name     = var.tenant_friendly_name
  allowed_logout_urls = var.allowed_logout_urls
  # ...
}

resource "auth0_client" "this" {
  for_each = { for c in var.clients : c.name => c }
  name       = each.value.name
  type       = each.value.type
  callback_urls = each.value.callback_urls
  redirect_uris = each.value.redirect_uris
  grant_types   = each.value.grant_types
}
```

> **`for_each` over lists** turns a variable list into multiple resources and
> keeps the code data-driven. It's the idiomatic way to manage "a set of
> clients" from a `tfvars` list.

### 6b. Secrets → variables sourced from GitHub secrets (NOT tfvars)

Secrets (client secrets, email provider API keys, etc.) must **not** be in
`terraform.tfvars` (which is committed). Pattern:

```hcl
# modules/auth0_demo/variables.tf
variable "client_secrets" {
  description = "Map of client name -> secret (M2M / confidential clients)"
  type        = map(string)
  sensitive   = true
  default     = {}
}
```

Feed it in the env root **from an environment variable** set by the GitHub
secret:

```hcl
# envs/prod/main.tf
module "auth0_demo" {
  source         = "../../modules/auth0_demo"
  env_name       = "prod"
  tenant_friendly_name = "Acme Prod"
  client_secrets   = { for k, v in var.client_secrets : k => v }
}
```

```hcl
# envs/prod/variables.tf (root-level)
variable "client_secrets" {
  type        = map(string)
  sensitive   = true
  default     = {}
}
```

And in the **workflow**, inject from the secret (see Step 8) via
`TF_VAR_client_secrets` (JSON) or by decoding a JSON secret into a map.

> **Rule of thumb:** anything a person would treat as a password/credential
> belongs in a GitHub secret + a `sensitive = true` variable — **never** in
> `*.tfvars` or committed `.tf`.

### 6c. Keep the import IDs out of committed HCL

The `import {}` blocks live in a **separate, temporary** file used only to
adopt state (Step 7). After the import is complete and state is populated,
the import blocks can remain (they're idempotent and document provenance) or
be removed — your choice. **Never** put real secret *values* into import IDs.

---

## 7. Import existing resources into state (the adoption step)

This is the crux: make Terraform **own** the resources that already exist,
without recreating them.

### 7a. Per-environment roots need their own state

Each `envs/<env>/` is a standalone root with its own HTTP backend (already
configured in `backend.tf`). The import writes into **that env's state**. Since
we have **one tenant**, pick the env that represents it (commonly **prod**, or
dedicate the tenant to one env). Import into **that env's root** first.

> If a single tenant is shared and you only have one set of live resources,
> import it in the env root that will be the "source of truth" (e.g. `prod`).
> The other envs would model the *same* tenant with env-specific overrides —
> decide explicitly how dev/uat/prod map to tenants before importing.

### 7b. Use the generated import blocks (or explicit `terraform import`)

**Option A — use the generated `auth0_import.tf` (fastest):**

```bash
# Work in a throwaway local root that references the generated files
mkdir -p /tmp/auth0-import && cd /tmp/auth0-import
cp tmp-auth0-tf/auth0_main.tf .
cp tmp-auth0-tf/auth0_import.tf .

# Provider creds from env:
export AUTH0_DOMAIN="<your-tenant>.auth0.com"
export AUTH0_CLIENT_ID="<client id>"
export AUTH0_CLIENT_SECRET="<secret>"

# Use a LOCAL backend for the import scratch root (or point at the target env
# backend). For a scratch adopt, local is simplest:
cat > local_backend_override.tf <<'HCL'
# (temporary) use local state for the scratch import root
HCL

terraform init -input=false
terraform apply -input=false   # runs the import blocks, populates state
```

**Option B — explicit `terraform import` per resource (more control):**

```bash
# Inside the target env root (e.g. envs/prod), with backend + provider creds:
cd envs/prod
export AUTH0_DOMAIN="<your-tenant>.auth0.com"
export AUTH0_CLIENT_ID="<client id>"
export AUTH0_CLIENT_SECRET="<secret>"
TF_HTTP_USERNAME="root" TF_HTTP_PASSWORD="<state pw>" terraform init -input=false

# Import each resource by its real ID:
terraform import auth0_tenant.this                 "<random-uuid>"          # singleton: any v4 UUID
terraform import auth0_client.web                   "<client_id e.g. ABC...>"
terraform import auth0_connection.password          "<conn id e.g. conn_...>"
terraform import auth0_resource_server.my_api       "<rs id e.g. ...>"
terraform import auth0_client_grant.web_to_api      "<grant id e.g. cgr_...>"
terraform import auth0_role.admin                   "<role id e.g. rol_...>"
terraform import auth0_organization.my_org          "<org id e.g. ...>"
terraform import auth0_email_provider.this          "<random-uuid>"          # singleton: any v4 UUID
terraform import auth0_guardian.this                "<random-uuid>"          # singleton: any v4 UUID
terraform import auth0_branding.this                "<random-uuid>"          # singleton: any v4 UUID
terraform import auth0_pages.this                   "<random-uuid>"          # singleton: any v4 UUID
terraform import auth0_prompt.this                  "<random-uuid>"          # singleton: any v4 UUID
```

### 7c. Singleton import IDs (important, verified)

Several tenant-level resources are **not** addressable by a real ID in the
Management API, so the provider accepts **any random string** (recommended: a
**version-4 UUID**) as the import ID:

| Resource | Import ID |
|----------|-----------|
| `auth0_tenant` | any v4 UUID |
| `auth0_email_provider` | any v4 UUID |
| `auth0_guardian` | any v4 UUID |
| `auth0_branding` | any v4 UUID |
| `auth0_pages` | any v4 UUID |
| `auth0_prompt` | any v4 UUID |

All other resources use their **real Auth0 IDs** (find them via the CLI, e.g.
`auth0 clients list -f json`, `auth0 connections list -f json`,
`auth0 apis list -f json`, `auth0 client-grants list -f json`,
`auth0 roles list -f json`, `auth0 orgs list -f json`).

> Generate a UUID with: `uuidgen` (macOS/Linux) or
> `python3 -c "import uuid;print(uuid.uuid4())"`.

### 7d. Validate with a clean plan

After import, run a plan. It should be **near-empty** (no create/destroy). Any
drift shown is a real difference between live config and your HCL — reconcile
it in the code, re-import if needed, and plan again until clean.

```bash
cd envs/prod   # (the env you imported into)
terraform plan -input=false -no-color
```

> A clean plan = Terraform now faithfully models the live tenant. **This is the
> gate before you touch CI/CD.**

---

## 8. Wire credentials into CI/CD (GitHub secrets)

Extend the existing secret pattern (`TF_HTTP_PASSWORD`) with Auth0 creds.

### 8a. Repo-level secrets (for the `build`/plan workflow)

The `build.yml` plan job runs without an environment gate, so it needs a
**repo-level** secret (as it already does for `TF_HTTP_PASSWORD`):

- `AUTH0_DOMAIN` = `<your-tenant>.auth0.com`
- `AUTH0_CLIENT_ID` = `<terraform-managed client id>`
- `AUTH0_CLIENT_SECRET` = `<secret>`  (or `AUTH0_API_TOKEN`)

> For secrets that must differ **per environment** (e.g. different M2M clients
> per env, or a per-env secret map), place them on the matching **GitHub
> Environment** (`dev`/`uat`/`prod`) exactly like `TF_HTTP_PASSWORD` — the
> `deploy.yml` job's `environment:` gate resolves them.

### 8b. Update the workflows to expose the vars

In `build.yml` (plan) and `deploy.yml` (apply), add the Auth0 vars alongside
the existing `TF_HTTP_*` ones:

```yaml
env:
  TF_HTTP_USERNAME: "root"
  TF_HTTP_PASSWORD: ${{ secrets.TF_HTTP_PASSWORD }}
  AUTH0_DOMAIN: ${{ secrets.AUTH0_DOMAIN }}
  AUTH0_CLIENT_ID: ${{ secrets.AUTH0_CLIENT_ID }}
  AUTH0_CLIENT_SECRET: ${{ secrets.AUTH0_CLIENT_SECRET }}
```

For a **secret map** (e.g. `client_secrets`), pass it as JSON and decode to a
Terraform variable:

```yaml
env:
  TF_VAR_client_secrets: ${{ secrets.AUTH0_CLIENT_SECRETS_JSON }}
```

where `AUTH0_CLIENT_SECRETS_JSON` = `{"web-client":"abc123","m2m-client":"def456"}`.

> `TF_VAR_<name>` auto-injects a variable by name — clean way to feed secrets
> without touching committed files.

---

## 9. Cutover: apply and retire the placeholder

With a clean plan and credentials wired:

1. **Remove the `null_resource` placeholder** and the `null` provider
   requirement from `modules/auth0_demo/` (and any env-root `hello_message`
   plumbing you no longer need).
2. **Deploy dev** first (manual `deploy` workflow, no approval gate):
   - Confirm `terraform init` picks up the `auth0` provider.
   - Confirm `plan` is clean (no drift) — it adopts the live resources.
3. **Deploy uat** (1 reviewer), then **prod** (2 reviewers) through the existing
   approval gates.
4. After a successful apply, **verify in the dashboard** that resources are
   unchanged (no accidental mutations) and that new changes flow through
   Terraform.

> **Rollback safety:** because we *imported* (adopted) rather than created, a
> failed apply doesn't destroy the tenant. If something goes wrong, fix the
> code and re-plan. State is the source of truth; the dashboard is now
> "downstream" of it.

---

## 10. Ongoing workflow & housekeeping

- **Change flow:** edit HCL in `modules/auth0_demo/` (and env `tfvars`) →
  `build` workflow plans on `beta/**` → `deploy` applies on `release/x.x.x`.
- **New resources:** add the block in the module, add any needed vars, and
  (if the resource already exists in the tenant) `terraform import` it once.
- **Drift detection:** run `terraform plan` regularly (the `build` workflow
  does this on `beta/**`). Unexpected diffs = someone changed the dashboard
  manually — either fix the code or re-import.
- **Secrets rotation:** rotate the M2M client secret in Auth0, then update the
  GitHub secret(s). No code change needed.
- **Keep the provider version pinned** (in `provider.tf`) to avoid surprise
  schema changes.

---

## 11. Gotchas & best-practice checklist

- ✅ **`auth0_tenant` cannot be created** via the provider — only managed.
  Fine here (tenant exists), but never expect `terraform apply` to create it.
- ✅ **Singleton resources** (`auth0_tenant`, `auth0_email_provider`,
  `auth0_guardian`, `auth0_branding`, `auth0_pages`, `auth0_prompt`) take a
  **random v4 UUID** as import ID.
- ✅ **`auth0_email_provider`** is **one per tenant** — don't model multiple.
- ✅ **`auth0_pages` `error` block conflicts** with `auth0_tenant`
  `error_page` — manage the error page in **one** place (prefer `auth0_tenant`).
- ✅ **Secrets never in `tfvars`** or committed `.tf` — use `sensitive`
  variables fed by `TF_VAR_*` / GitHub secrets.
- ✅ **Keep resource addresses stable** when splitting files; only the name
  matters for state.
- ✅ **`for_each`** for collections (clients, roles, grants) keeps code
  data-driven and the `tfvars` readable.
- ✅ **Adopt before you apply** — the first plan must be clean; never let
  Terraform "create" an existing resource (it would fail or duplicate).
- ✅ **Least-privilege M2M client** with only the scopes you manage; expand as
  you adopt more resource types.
- ✅ **Dev → UAT → Prod** through the existing approval gates.
- ✅ **One env root = source of truth** for a shared tenant; be explicit about
  how dev/uat/prod map to tenants before importing.

---

## Quick reference: commands

```bash
# 1) CLI creds
export AUTH0_DOMAIN="<tenant>.auth0.com"
export AUTH0_CLIENT_ID="<id>"
export AUTH0_CLIENT_SECRET="<secret>"

# 2) Export starting point
auth0 terraform generate --output-dir tmp-auth0-tf --force

# 3) (optional) inspect generated files
cat tmp-auth0-tf/auth0_generated.tf

# 4) Import into the target env root (example)
cd envs/prod
TF_HTTP_USERNAME="root" TF_HTTP_PASSWORD="<pw>" terraform init -input=false
terraform import auth0_tenant.this "$(python3 -c 'import uuid;print(uuid.uuid4())')"
terraform import auth0_client.web "<client_id>"
# ... etc.

# 5) Verify clean plan
terraform plan -input=false -no-color

# 6) Apply (via the deploy workflow, not manually for prod)
```
