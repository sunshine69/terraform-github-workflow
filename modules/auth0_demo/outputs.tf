# =============================================================================
# modules/auth0_demo — outputs
# =============================================================================

output "hello_message" {
  description = "The hello-world message"
  value       = var.hello_message
}

output "env_name" {
  description = "Which environment this module was applied to"
  value       = var.env_name
}
