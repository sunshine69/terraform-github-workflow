# Auth0 Terraform Demo — Secure CI/CD Pipeline

A GitHub Actions pipeline that runs Terraform to provision **Auth0** resources
across three environments: **dev, uat, prod**.

## Architecture

Each environment is a **standalone Terraform root** (its own `backend.tf` +
`main.tf` + `terraform.tfvars`). All shared resource logic lives in a single
module (`modules/auth0_demo/`) that every env instantiates.

```
modules/
└── auth0_demo/          # shared logic (main.tf, variables.tf, outputs.tf)
envs/
├── dev/                 # dev TF root
│   ├── backend.tf       # dev HTTP backend
│   ├── main.tf          # calls modules/auth0_demo with dev args
│   └── terraform.tfvars # dev-specific variable values
├── uat/                 # uat TF root
│   ├── backend.tf       # uat HTTP backend
│   ├── main.tf          # calls modules/auth0_demo with uat args
│   └── terraform.tfvars # uat-specific variable values
└── prod/                # prod TF root
    ├── backend.tf       # prod HTTP backend
    ├── main.tf          # calls modules/auth0_demo with prod args
    └── terraform.tfvars # prod-specific variable values
```

## How the password works

The HTTP backend's `password` is **not** stored in any file. Terraform reads
it from the `TF_HTTP_PASSWORD` environment variable. GitHub sets that variable
from the secret on the matching **GitHub Environment** (`dev`, `uat`, or
`prod`), so the same secret name can hold a **different value per environment**
without ever committing a secret.

```
GitHub Environment "dev"  →  TF_HTTP_PASSWORD = "dev-password"
GitHub Environment "uat"  →  TF_HTTP_PASSWORD = "uat-password"
GitHub Environment "prod" →  TF_HTTP_PASSWORD = "prod-password"
```

## Workflow

| Stage           | Trigger              | Action                         | Approval         |
|-----------------|----------------------|--------------------------------|------------------|
| Deploy (dev)    | manual on release    | `init` + `plan` + `apply`     | none             |
| Deploy (uat)    | manual on release    | `init` + `plan` + `apply`     | required_reviewers |
| Deploy (prod)   | manual on release    | `init` + `plan` + `apply`     | required_reviewers (x2) |

`deploy.yml` cd's into `envs/<env>/` and runs terraform there. The GitHub
`environment:` gate pulls the matching `TF_HTTP_PASSWORD` secret and (for
uat/prod) requires reviewer approval before apply runs.

## Prerequisites

1. Terraform 1.7+ (workflow pins 1.9).
2. An HTTP backend host (e.g. `https://play.terraform.io`).
3. GitHub repo with three environments configured (see `.github/environments/`).
4. A `TF_HTTP_PASSWORD` secret on **each** GitHub environment with the
   password for that env's state.

## Configuration

1. Create the three GitHub environments (`dev`, `uat`, `prod`) with a
   `TF_HTTP_PASSWORD` secret on each.
2. Add `required_reviewers` to `.github/environments/{uat,prod}.yml`.
3. Edit `envs/<env>/terraform.tfvars` to change the `hello_message` value —
   this is the variable that flows through the module and produces an
   observable effect in plan/apply.
4. Push to a `release/x.x.x` branch and run the deploy workflow manually.

## Security notes

- No secrets are committed: `TF_HTTP_PASSWORD` lives only in GitHub
  environment secrets, resolved at deploy time.
- Plan and apply are in the same job, but the GitHub environment gate
  (reviewers) blocks apply for uat/prod.
- Least privilege: prod requires **two** reviewers by default.
- `deploy.yml` validates the branch is a `release/x.x.x` branch before apply.

## Notes

- The `null_resource` in `modules/auth0_demo/main.tf` is a placeholder for
  real Auth0 resources (e.g. `auth0_tenant`). Uncomment the Auth0 resource
  block and add the `auth0` provider when you're ready to provision real
  resources.
- Each env's `terraform.tfvars` is the only place env-specific values are set.
  Changing `hello_message` there changes what the module outputs.
