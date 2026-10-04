# =============================================================================
# uat — instantiate modules/auth0_demo
# =============================================================================
module "auth0_demo" {
  source      = "../../modules/auth0_demo"
  env_name   = "uat"
  hello_message = var.hello_message
}

output "hello" {
  value = module.auth0_demo.hello_message
}
