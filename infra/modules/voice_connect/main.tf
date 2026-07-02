# Amazon Connect — default VoiceProvider (§1).
# Minimal: instance + placeholder contact flow + optional DID. Queue/routing/Lex
# code-hook are Days 3-4. The contact flow JSON is a placeholder — replace with the
# real Polly + Lex->DialogTurn flow during the voice spike.

variable "name_prefix" { type = string }
variable "claim_phone_number" { type = bool }
variable "dialog_fn_arn" { type = string }
variable "adapter_source_dir" { type = string }

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

# --- Phase B: Lex V2 code-hook adapter Lambda (§1) ---
# Lex invokes this per caller utterance; it calls the dialog engine and maps the
# result to a Lex response. Lex invoke permission is granted by scripts/build_lex.sh
# once the bot alias exists (avoids a chicken/egg with the CLI-built bot).

data "archive_file" "adapter" {
  type        = "zip"
  source_dir  = var.adapter_source_dir
  output_path = "${path.module}/.build/connect_adapter.zip"
}

data "aws_iam_policy_document" "adapter_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "adapter" {
  name              = "/aws/lambda/${var.name_prefix}-connect-adapter"
  retention_in_days = 14
}

resource "aws_iam_role" "adapter" {
  name               = "${var.name_prefix}-connect-adapter"
  assume_role_policy = data.aws_iam_policy_document.adapter_assume.json
}

data "aws_iam_policy_document" "adapter_perms" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.adapter.arn}:*"]
  }
  statement {
    sid       = "InvokeDialog"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.dialog_fn_arn]
  }
  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "adapter" {
  role   = aws_iam_role.adapter.id
  policy = data.aws_iam_policy_document.adapter_perms.json
}

resource "aws_lambda_function" "adapter" {
  function_name    = "${var.name_prefix}-connect-adapter"
  role             = aws_iam_role.adapter.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.adapter.output_path
  source_code_hash = data.archive_file.adapter.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DIALOG_FN = var.dialog_fn_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.adapter]
}

output "adapter_function_arn" {
  value = aws_lambda_function.adapter.arn
}

output "adapter_function_name" {
  value = aws_lambda_function.adapter.function_name
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

# The claimed source number (E.164) used as SourcePhoneNumber for outbound calls.
# null until claim_phone_number = true (Day-0 provisioning; ~$1/mo).
output "phone_number" {
  value = var.claim_phone_number ? aws_connect_phone_number.did[0].phone_number : null
}
