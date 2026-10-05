# =============================================================================
# dev — instantiate modules/auth0_demo
# =============================================================================

variable "hello_message" {
  description = "Message to output (change this to see an effect in plan/apply)"
  type        = string
  default     = "Hello World"
}

module "auth0_demo" {
  source      = "../../modules/auth0_demo"
  env_name   = "dev"
  hello_message = var.hello_message
}

output "hello" {
  value = module.auth0_demo.hello_message
}
