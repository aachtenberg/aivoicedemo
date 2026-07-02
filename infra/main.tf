# Root module — wires the pieces. See ARCHITECTURE.md for the why of each.
#
# Flow:  intake(API GW) -> RepairOrderCompleted(EventBridge) -> Step Functions job
#        -> DialogTurn(Bedrock+Guardrail) <- behaviour from AppConfig
#        -> outcome in DynamoDB + CallCompleted event.  Voice provider is swappable.

# ---- Foundations -----------------------------------------------------------
module "data_store" {
  source      = "./modules/data_store"
  name_prefix = local.name_prefix
}

module "event_bus" {
  source      = "./modules/event_bus"
  name_prefix = local.name_prefix
}

# ---- Safety + behaviour (§9, §10) ------------------------------------------
module "guardrail" {
  source      = "./modules/guardrail"
  name_prefix = local.name_prefix
}

module "dialog_config" {
  source      = "./modules/dialog_config"
  name_prefix = local.name_prefix
  config_json = file("${local.config_dir}/dialog-config.json")
  schema_json = file("${local.config_dir}/dialog-config.schema.json")
}

# ---- Dialog engine (§2, §9) ------------------------------------------------
module "dialog_engine" {
  source            = "./modules/dialog_engine"
  name_prefix       = local.name_prefix
  source_dir        = "${local.src_dir}/dialog_engine"
  table_name        = module.data_store.table_name
  table_arn         = module.data_store.table_arn
  bedrock_model_id  = var.bedrock_model_id
  guardrail_id      = module.guardrail.guardrail_id
  guardrail_version = module.guardrail.guardrail_version
  appconfig_app     = module.dialog_config.application_id
  appconfig_env     = module.dialog_config.environment_id
  appconfig_profile = module.dialog_config.profile_id
  voice_provider    = var.voice_provider
}

# ---- Orchestration + telemetry (§8) ----------------------------------------
module "orchestrator" {
  source         = "./modules/orchestrator"
  name_prefix    = local.name_prefix
  src_dir        = local.src_dir
  event_bus_name = module.event_bus.bus_name
  event_bus_arn  = module.event_bus.bus_arn
  table_arn      = module.data_store.table_arn
  dialog_fn_arn  = module.dialog_engine.function_arn
  max_attempts   = var.max_call_attempts
}

# ---- Voice provider (§1) — only the selected one is instantiated -----------
module "voice_connect" {
  source             = "./modules/voice_connect"
  count              = var.voice_provider == "connect" ? 1 : 0
  name_prefix        = local.name_prefix
  claim_phone_number = var.claim_phone_number
  dialog_fn_arn      = module.dialog_engine.function_arn
  adapter_source_dir = "${local.src_dir}/connect_adapter"
}

module "voice_twilio" {
  source        = "./modules/voice_twilio"
  count         = var.voice_provider == "twilio" ? 1 : 0
  name_prefix   = local.name_prefix
  source_dir    = "${local.src_dir}/twilio_adapter"
  dialog_fn_arn = module.dialog_engine.function_arn
}

# ---- Observability dashboard (§8) ------------------------------------------
module "dashboard" {
  source            = "./modules/dashboard"
  name_prefix       = local.name_prefix
  region            = var.aws_region
  provider_name     = var.voice_provider
  dialog_fn         = module.dialog_engine.function_name
  intake_fn         = module.orchestrator.intake_function_name
  state_machine_arn = module.orchestrator.state_machine_arn
  api_id            = module.orchestrator.api_id
  rule_name         = module.orchestrator.rule_name
  dialog_log_group  = "/aws/lambda/${local.name_prefix}-dialog"
}

# ---- Infra-shaped config (§10) ---------------------------------------------
resource "aws_ssm_parameter" "provider" {
  name  = "/${var.project}/${var.environment}/provider"
  type  = "String"
  value = var.voice_provider
}
