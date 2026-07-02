# Orchestration + ingress (§2, §8):
#   API GW -> intake Lambda -> RepairOrderCompleted -> EventBridge rule -> Step Functions.

variable "name_prefix" { type = string }
variable "src_dir" { type = string }
variable "event_bus_name" { type = string }
variable "event_bus_arn" { type = string }
variable "table_arn" { type = string }
variable "dialog_fn_arn" { type = string }
variable "max_attempts" { type = number }

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---- intake lambda ---------------------------------------------------------
data "archive_file" "intake" {
  type        = "zip"
  source_dir  = "${var.src_dir}/intake"
  output_path = "${path.module}/.build/intake.zip"
}

resource "aws_iam_role" "intake" {
  name               = "${var.name_prefix}-intake"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "intake" {
  name              = "/aws/lambda/${var.name_prefix}-intake"
  retention_in_days = 14
}

data "aws_iam_policy_document" "intake_perms" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.intake.arn}:*"]
  }
  statement {
    actions   = ["events:PutEvents"]
    resources = [var.event_bus_arn]
  }
  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "intake_perms" {
  role   = aws_iam_role.intake.id
  policy = data.aws_iam_policy_document.intake_perms.json
}

resource "aws_lambda_function" "intake" {
  function_name    = "${var.name_prefix}-intake"
  role             = aws_iam_role.intake.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.intake.output_path
  source_code_hash = data.archive_file.intake.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.intake]

  environment {
    variables = {
      EVENT_BUS_NAME = var.event_bus_name
    }
  }
}

# ---- HTTP API (the demo simulator) -----------------------------------------
resource "aws_apigatewayv2_api" "intake" {
  name          = "${var.name_prefix}-intake"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "intake" {
  api_id                 = aws_apigatewayv2_api.intake.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.intake.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "intake" {
  api_id    = aws_apigatewayv2_api.intake.id
  route_key = "POST /orders/{orderId}/ready"
  target    = "integrations/${aws_apigatewayv2_integration.intake.id}"
}

resource "aws_apigatewayv2_stage" "intake" {
  api_id      = aws_apigatewayv2_api.intake.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "intake_api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.intake.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.intake.execution_arn}/*/*"
}

# ---- Step Functions call-job state machine (§8) ----------------------------
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name_prefix}-calljob"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

# Own the execution log group — Step Functions history + CloudWatch logs (§8).
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-call-job"
  retention_in_days = 14
}

data "aws_iam_policy_document" "sfn_perms" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [var.dialog_fn_arn]
  }
  statement {
    actions   = ["events:PutEvents"]
    resources = [var.event_bus_arn]
  }
  # CloudWatch Logs delivery perms required for SFN logging (must be resource "*").
  statement {
    sid = "SfnLogging"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "XRay"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn_perms" {
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn_perms.json
}

resource "aws_sfn_state_machine" "job" {
  name     = "${var.name_prefix}-call-job"
  role_arn = aws_iam_role.sfn.arn
  definition = templatefile("${path.module}/asl.json.tftpl", {
    dialog_fn_arn = var.dialog_fn_arn
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tracing_configuration {
    enabled = true # X-Ray (§8)
  }
}

# ---- EventBridge rule: RepairOrderCompleted -> start one execution ----------
resource "aws_cloudwatch_event_rule" "ready" {
  name           = "${var.name_prefix}-order-ready"
  event_bus_name = var.event_bus_name
  event_pattern = jsonencode({
    "detail-type" = ["RepairOrderCompleted"]
  })
}

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  name               = "${var.name_prefix}-events"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events_perms" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.job.arn]
  }
}

resource "aws_iam_role_policy" "events_perms" {
  role   = aws_iam_role.events.id
  policy = data.aws_iam_policy_document.events_perms.json
}

resource "aws_cloudwatch_event_target" "sfn" {
  rule           = aws_cloudwatch_event_rule.ready.name
  event_bus_name = var.event_bus_name
  arn            = aws_sfn_state_machine.job.arn
  role_arn       = aws_iam_role.events.arn
}

output "intake_url" {
  value = "${aws_apigatewayv2_api.intake.api_endpoint}/orders/{orderId}/ready"
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.job.arn
}

output "intake_function_name" {
  value = aws_lambda_function.intake.function_name
}

output "api_id" {
  value = aws_apigatewayv2_api.intake.id
}

output "rule_name" {
  value = aws_cloudwatch_event_rule.ready.name
}
