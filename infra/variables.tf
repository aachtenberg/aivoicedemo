variable "aws_region" {
  description = "AWS region. Bedrock + Connect availability assumed for us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  type    = string
  default = "aivoicedemo"
}

variable "environment" {
  type    = string
  default = "demo"
}

variable "voice_provider" {
  description = "Which VoiceProvider to instantiate (§1). Swappable."
  type        = string
  default     = "connect"

  validation {
    condition     = contains(["connect", "twilio", "sns"], var.voice_provider)
    error_message = "voice_provider must be one of: connect, twilio, sns."
  }
}

variable "claim_phone_number" {
  description = "Claim a Connect DID (costs money; Day-0 provisioning). Off by default."
  type        = bool
  default     = false
}

variable "bedrock_model_id" {
  description = "Bedrock inference-profile ID for the dialog engine (§ model choice). Confirmed via list-inference-profiles."
  type        = string
  default     = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
}

variable "max_call_attempts" {
  description = "Retry cap for the call-job state machine (§8)."
  type        = number
  default     = 3
}
