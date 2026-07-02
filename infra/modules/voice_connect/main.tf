# Amazon Connect — default VoiceProvider (§1).
# Minimal: instance + placeholder contact flow + optional DID. Queue/routing/Lex
# code-hook are Days 3-4. The contact flow JSON is a placeholder — replace with the
# real Polly + Lex->DialogTurn flow during the voice spike.

variable "name_prefix" { type = string }
variable "claim_phone_number" { type = bool }

resource "aws_connect_instance" "main" {
  identity_management_type = "CONNECT_MANAGED"
  instance_alias           = var.name_prefix
  inbound_calls_enabled    = true
  outbound_calls_enabled   = true

  # Off by default here: Contact Lens adds ~$0.015/min of analytics we don't need
  # for the demo. Re-enable if the client wants call transcription/sentiment.
  contact_lens_enabled = false
}

resource "aws_connect_contact_flow" "notify" {
  instance_id = aws_connect_instance.main.id
  name        = "${var.name_prefix}-notify"
  type        = "CONTACT_FLOW"
  content     = file("${path.module}/flows/notify.json")
}

# Claiming a number costs money — gated off by default (§ Day-0 provisioning).
resource "aws_connect_phone_number" "did" {
  count        = var.claim_phone_number ? 1 : 0
  target_arn   = aws_connect_instance.main.arn
  country_code = "US"
  type         = "DID"
}

output "instance_id" {
  value = aws_connect_instance.main.id
}

output "instance_arn" {
  value = aws_connect_instance.main.arn
}

output "contact_flow_id" {
  value = aws_connect_contact_flow.notify.contact_flow_id
}
