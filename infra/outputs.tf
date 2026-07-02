output "intake_url" {
  description = "POST /orders/{orderId}/ready to trigger the demo."
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
