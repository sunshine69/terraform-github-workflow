# =============================================================================
# modules/auth0_demo — input variables
# =============================================================================

variable "env_name" {
  description = "Target environment name (dev, uat, prod)"
  type        = string
}

variable "hello_message" {
  description = "Message to output (change this to see an effect in plan/apply)"
  type        = string
  default     = "Hello World"
}
