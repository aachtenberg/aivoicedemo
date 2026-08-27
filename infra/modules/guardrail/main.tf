# Bedrock Guardrail — §9 #4. Applied to caller input AND model output.
# Edit here, publish a new version, then flip guardrail_version in AppConfig to cut over.

variable "name_prefix" {
  type = string
}

resource "aws_bedrock_guardrail" "dialog" {
  name                      = "${var.name_prefix}-dialog"
  blocked_input_messaging   = "I can only help with this re-route."
  blocked_outputs_messaging = "I'm not able to help with that on this call."

  # PII the agent must never emit, even if one leaked into context (backstop to §9 #1).
  sensitive_information_policy_config {
    pii_entities_config {
      type   = "CREDIT_DEBIT_CARD_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "US_SOCIAL_SECURITY_NUMBER"
      action = "BLOCK"
    }
    pii_entities_config {
      type   = "ADDRESS"
      action = "BLOCK"
    }
  }

  # Guardrails enforce the HARD risks (payments/PII/saved-places/injection). Topic-scoping
  # nuance — "stay on this re-route, but handle skip-a-stop naturally" — is the model +
  # system prompt's job (§9 layering). A broad "OffTopic" DENY topic false-positives on
  # in-scope speech like "skip the pharmacy", so it's intentionally NOT used here.
  topic_policy_config {
    topics_config {
      name       = "Payments"
      type       = "DENY"
      definition = "Any discussion of card numbers, billing, balances, or taking payment."
      examples   = ["what's the card on file", "can I pay now", "what do I owe"]
    }
    topics_config {
      name       = "SavedPlaces"
      type       = "DENY"
      definition = "Requests for a home, work, or school street address, coordinates, or other saved-place details that would not belong on a voicemail."
      examples   = ["what's my home address", "where does my kid go to school", "read me the coordinates for home"]
    }
  }

  # Prompt-injection detection on caller speech.
  content_policy_config {
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }

  # NOTE: contextual-grounding (RELEVANCE/GROUNDING) is a RAG feature — it scores the
  # answer against a provided source. This dialog isn't RAG, so with no grounding source
  # it intervenes on every turn. Task-scoping is enforced by the denied-topics policy
  # above plus the system prompt (§9), not grounding. Re-add only if we add retrieval.
}

resource "aws_bedrock_guardrail_version" "dialog" {
  guardrail_arn = aws_bedrock_guardrail.dialog.guardrail_arn
  description   = "auto-published on guardrail change"

  # Cut a fresh published version whenever the guardrail config changes, so the
  # pinned guardrail_version the Lambda uses tracks edits (§10 version-pointer model).
  lifecycle {
    replace_triggered_by = [aws_bedrock_guardrail.dialog]
  }
}

output "guardrail_id" {
  value = aws_bedrock_guardrail.dialog.guardrail_id
}

output "guardrail_version" {
  value = aws_bedrock_guardrail_version.dialog.version
}
