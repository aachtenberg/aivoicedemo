# AWS AppConfig — §10. Behaviour (prompt/copy/knobs) as validated, staged config.
# JSON-schema validator rejects a malformed doc at PUBLISH time, before it can ship.

variable "name_prefix" {
  type = string
}

variable "config_json" {
  type = string
}

variable "schema_json" {
  type = string
}

resource "aws_appconfig_application" "main" {
  name = var.name_prefix
}

resource "aws_appconfig_environment" "main" {
  name           = "demo"
  application_id = aws_appconfig_application.main.id
}

resource "aws_appconfig_configuration_profile" "dialog" {
  application_id = aws_appconfig_application.main.id
  name           = "dialog"
  location_uri   = "hosted"

  validator {
    type    = "JSON_SCHEMA"
    content = var.schema_json
  }
}

resource "aws_appconfig_hosted_configuration_version" "dialog" {
  application_id           = aws_appconfig_application.main.id
  configuration_profile_id = aws_appconfig_configuration_profile.dialog.configuration_profile_id
  content_type             = "application/json"
  content                  = var.config_json
}

# Fast rollout for the demo; add CloudWatch alarm monitors on the environment
# for auto-rollback in production (§10, Day-9 polish).
resource "aws_appconfig_deployment_strategy" "quick" {
  name                           = "${var.name_prefix}-quick"
  deployment_duration_in_minutes = 1
  final_bake_time_in_minutes     = 1
  growth_factor                  = 100
  replicate_to                   = "NONE"
}

output "application_id" {
  value = aws_appconfig_application.main.id
}

output "environment_id" {
  value = aws_appconfig_environment.main.environment_id
}

output "profile_id" {
  value = aws_appconfig_configuration_profile.dialog.configuration_profile_id
}
