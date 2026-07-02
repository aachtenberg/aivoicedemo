# DialogTurn Lambda — §2, §9. Least-privilege IAM: Bedrock invoke + guardrail,
# scoped DynamoDB, AppConfig read. Nothing else.

variable "name_prefix" { type = string }
variable "source_dir" { type = string }
variable "table_name" { type = string }
variable "table_arn" { type = string }
variable "bedrock_model_id" { type = string }
variable "guardrail_id" { type = string }
variable "guardrail_version" { type = string }
variable "appconfig_app" { type = string }
variable "appconfig_env" { type = string }
variable "appconfig_profile" { type = string }
variable "voice_provider" {
  type    = string
  default = "connect"
}

data "archive_file" "zip" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/dialog_engine.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-dialog"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Own the log group (retention + explicit) instead of letting Lambda auto-create it.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-dialog"
  retention_in_days = 14
}

data "aws_iam_policy_document" "perms" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }
  statement {
    sid       = "Bedrock"
    actions   = ["bedrock:InvokeModel", "bedrock:ApplyGuardrail"]
    resources = ["*"]
  }
  statement {
    sid       = "Dynamo"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query"]
    resources = [var.table_arn, "${var.table_arn}/index/*"]
  }
  statement {
    sid       = "AppConfig"
    actions   = ["appconfig:GetLatestConfiguration", "appconfig:StartConfigurationSession"]
    resources = ["*"]
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

resource "aws_lambda_function" "this" {
  function_name    = "${var.name_prefix}-dialog"
  role             = aws_iam_role.this.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 15
  filename         = data.archive_file.zip.output_path
  source_code_hash = data.archive_file.zip.output_base64sha256

  tracing_config {
    mode = "Active" # X-Ray (§8) — lightweight distributed tracing, no OTel collector weight
  }

  depends_on = [aws_cloudwatch_log_group.this]

  # TODO(day7): add the AWS-AppConfig-Extension layer ARN for us-east-1 so
  # load_config() reads localhost:2772. Left off to avoid a hardcoded ARN.
  # layers = [var.appconfig_extension_arn]

  environment {
    variables = {
      TABLE_NAME        = var.table_name
      BEDROCK_MODEL_ID  = var.bedrock_model_id
      GUARDRAIL_ID      = var.guardrail_id
      GUARDRAIL_VERSION = var.guardrail_version
      APPCONFIG_APP     = var.appconfig_app
      APPCONFIG_ENV     = var.appconfig_env
      APPCONFIG_PROFILE = var.appconfig_profile
      VOICE_PROVIDER    = var.voice_provider
    }
  }
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "function_name" {
  value = aws_lambda_function.this.function_name
}
