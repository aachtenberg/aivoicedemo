# Twilio — swap VoiceProvider (§1). AWS side only: a TwiML webhook (API GW ->
# adapter Lambda -> DialogTurn). The Twilio number/app itself is provisioned out
# of band (kept light — we don't depend on the early Twilio TF provider).

variable "name_prefix" { type = string }
variable "source_dir" { type = string }
variable "dialog_fn_arn" { type = string }

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "archive_file" "zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/twilio_adapter.zip"
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-twilio"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-twilio-adapter"
  retention_in_days = 14
}

data "aws_iam_policy_document" "perms" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [var.dialog_fn_arn]
  }
  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "perms" {
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.perms.json
}

resource "aws_lambda_function" "adapter" {
  function_name    = "${var.name_prefix}-twilio-adapter"
  role             = aws_iam_role.this.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.this]

  environment {
    variables = {
      DIALOG_FN = var.dialog_fn_arn
    }
  }
}

resource "aws_apigatewayv2_api" "webhook" {
  name          = "${var.name_prefix}-twilio"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "webhook" {
  api_id                 = aws_apigatewayv2_api.webhook.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.adapter.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id    = aws_apigatewayv2_api.webhook.id
  route_key = "POST /voice/twiml"
  target    = "integrations/${aws_apigatewayv2_integration.webhook.id}"
}

resource "aws_apigatewayv2_stage" "webhook" {
  api_id      = aws_apigatewayv2_api.webhook.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "webhook" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.adapter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.webhook.execution_arn}/*/*"
}

output "webhook_url" {
  value = "${aws_apigatewayv2_api.webhook.api_endpoint}/voice/twiml"
}
