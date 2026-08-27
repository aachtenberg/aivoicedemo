output "intake_url" {
  description = "POST /routes/{routeId}/disrupted to trigger the demo."
  value       = module.orchestrator.intake_url
}

output "state_machine_arn" {
  value = module.orchestrator.state_machine_arn
}

output "dynamodb_table" {
  value = module.data_store.table_name
}

output "event_bus" {
  value = module.event_bus.bus_name
}

output "guardrail_id" {
  value = module.guardrail.guardrail_id
}

output "dialog_function" {
  value = module.dialog_engine.function_name
}

output "active_voice_provider" {
  value = var.voice_provider
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${module.dashboard.dashboard_name}"
}

# Connect outbound spike (§ voice spike). null when voice_provider != "connect".
output "connect_instance_id" {
  value = one(module.voice_connect[*].instance_id)
}

output "connect_contact_flow_id" {
  value = one(module.voice_connect[*].contact_flow_id)
}

output "connect_source_number" {
  description = "Claimed outbound source number (null until claim_phone_number = true)."
  value       = one(module.voice_connect[*].phone_number)
}

output "connect_adapter_function_name" {
  description = "Lex V2 code-hook adapter (Phase B) — build_lex.sh binds the bot to it."
  value       = one(module.voice_connect[*].adapter_function_name)
}

output "connect_adapter_function_arn" {
  value = one(module.voice_connect[*].adapter_function_arn)
}
