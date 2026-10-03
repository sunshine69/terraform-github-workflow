# =============================================================================
# dev - consolidated HCL (backend + provider + resources + outputs)
# =============================================================================
terraform {
  required_version = ">= 1.7"

  backend "http" {
    encrypt = true
  }

  required_providers {
    auth0 = {
      source  = "auth0/auth0"
      version = ">= 1.4"
    }
  }
}

# --- Placeholder S3 backend (commented out) ---------------------------------
# terraform {
#   backend "s3" {
#     bucket         = "your-tf-state-bucket"
#     key            = "dev/state.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "your-tf-locks-table"
#     encrypt        = true
#   }
# }

# --- Provider (uncomment with real credentials via env vars) ----------------
# provider "auth0" {}

# --- Hello World placeholder ------------------------------------------------
resource "null_resource" "dev_hello_world" {}

# --- Placeholder Auth0 resource (uncomment when ready) ----------------------
# resource "auth0_tenant" "dev" {
#   friendly_name = "dev"
#   logo_url      = "https://example.com/logo.png"
# }

output "dev_output" {
  description = "Hello world output for dev"
  value       = null_resource.dev_hello_world.id
}
