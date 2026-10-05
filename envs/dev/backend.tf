# =============================================================================
# dev — backend (http)
# address/username/password are resolved from TF_HTTP_* env vars
# (TF_HTTP_PASSWORD is set by the GitHub "dev" environment secret)
# =============================================================================
terraform {
  backend "http" {
    address  = "https://tfstate.kaykraft.org/tfstate/sctauth0/dev"
    username = "sctauth0"
  }

  required_version = ">= 1.7"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}
