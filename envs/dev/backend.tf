# =============================================================================
# dev — backend (http)
# address/username/password are resolved from TF_HTTP_* env vars
# (TF_HTTP_PASSWORD is set by the GitHub "dev" environment secret)
# =============================================================================
terraform {
  backend "http" {
    address  = "https://play.terraform.io/terraform/state/dev"
    username = "root"
    encrypt  = true
  }

  required_version = ">= 1.7"
  required_providers {
    null = {
      source  = "null/null"
      version = ">= 3.0"
    }
  }
}
