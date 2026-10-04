# =============================================================================
# modules/auth0_demo — core shared logic
# All environment-specific resource definitions live here.
# Each env dir instantiates this module and passes its own args.
# =============================================================================

# --- Hello World placeholder (real Auth0 resources go here) ---------------
resource "null_resource" "hello_world" {
  triggers = {
    message = var.hello_message
    env     = var.env_name
  }
}

# --- Placeholder Auth0 resource (uncomment when ready) --------------------
# resource "auth0_tenant" "this" {
#   friendly_name = var.env_name
#   logo_url      = "https://example.com/logo.png"
# }
