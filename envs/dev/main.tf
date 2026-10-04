# =============================================================================
# dev — instantiate modules/auth0_demo
# =============================================================================
module "auth0_demo" {
  source      = "../../modules/auth0_demo"
  env_name   = "dev"
  hello_message = var.hello_message
}

output "hello" {
  value = module.auth0_demo.hello_message
}
