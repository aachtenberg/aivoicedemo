# Comprehensive CloudWatch dashboard (§8): golden signals (singleValue + gauge) on top,
# outcome mix (bar/pie), then trend lines and a Logs Insights panel.
# Grafana can consume the same metrics + X-Ray later (native data sources).

variable "name_prefix" { type = string }
variable "region" { type = string }
variable "provider_name" { type = string }
variable "dialog_fn" { type = string }
variable "intake_fn" { type = string }
variable "state_machine_arn" { type = string }
variable "api_id" { type = string }
variable "rule_name" { type = string }
variable "dialog_log_group" { type = string }

locals {
  ns  = "VoiceDemo"
  arn = var.state_machine_arn
  fn  = var.dialog_fn

  # SEARCH expressions reused across bar/pie
  outcomes_search = "SEARCH('{${local.ns},Provider,Action} MetricName=\"DialogTurn\"', 'Sum', 300)"

  widgets = [
    { type = "text", x = 0, y = 0, width = 24, height = 1,
    properties = { markdown = "# ${var.name_prefix} — Voice Call Demo · golden signals · outcomes · latency · traces" } },

    # ============ GOLDEN SIGNALS (traffic · latency · errors · saturation) ============
    { type = "text", x = 0, y = 1, width = 24, height = 1,
    properties = { markdown = "## Golden signals — traffic · latency · errors · saturation" } },

    # traffic
    { type = "metric", x = 0, y = 2, width = 3, height = 4, properties = {
      title = "Traffic · dialog turns", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [[local.ns, "DialogTurn", "Provider", var.provider_name, { stat = "Sum" }]]
    } },
    { type = "metric", x = 3, y = 2, width = 3, height = 4, properties = {
      title = "Traffic · calls placed", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [["AWS/States", "ExecutionsStarted", "StateMachineArn", local.arn, { stat = "Sum" }]]
    } },
    # latency
    { type = "metric", x = 6, y = 2, width = 3, height = 4, properties = {
      title = "Latency · dialog p95 (ms)", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [["AWS/Lambda", "Duration", "FunctionName", local.fn, { stat = "p95" }]]
    } },
    { type = "metric", x = 9, y = 2, width = 3, height = 4, properties = {
      title = "Latency · Bedrock avg (ms)", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [[{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InvocationLatency\"', 'Average', 300)", id = "bl", label = "" }]]
    } },
    # errors
    { type = "metric", x = 12, y = 2, width = 3, height = 4, properties = {
      title = "Errors · Lambda", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [["AWS/Lambda", "Errors", "FunctionName", local.fn, { stat = "Sum" }]]
    } },
    { type = "metric", x = 15, y = 2, width = 3, height = 4, properties = {
      title = "Errors · converse failures", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [[local.ns, "ConverseFailed", "Provider", var.provider_name, { stat = "Sum" }]]
    } },
    # saturation
    { type = "metric", x = 18, y = 2, width = 3, height = 4, properties = {
      title = "Saturation · throttles", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [["AWS/Lambda", "Throttles", "FunctionName", local.fn, { stat = "Sum" }]]
    } },
    { type = "metric", x = 21, y = 2, width = 3, height = 4, properties = {
      title = "Saturation · concurrency", region = var.region, view = "singleValue", sparkline = true, period = 300,
      metrics = [["AWS/Lambda", "ConcurrentExecutions", "FunctionName", local.fn, { stat = "Maximum" }]]
    } },

    # ============ OUTCOMES (gauge + bar + pie) ============
    { type = "text", x = 0, y = 6, width = 24, height = 1,
    properties = { markdown = "## Outcomes & SLA" } },

    { type = "metric", x = 0, y = 7, width = 6, height = 7, properties = {
      title = "Dialog p95 vs 5s budget", region = var.region, view = "gauge", period = 300,
      yAxis = { left = { min = 0, max = 5000 } },
      metrics = [["AWS/Lambda", "Duration", "FunctionName", local.fn, { stat = "p95" }]]
    } },
    { type = "metric", x = 6, y = 7, width = 9, height = 7, properties = {
      title = "Outcomes by action (count)", region = var.region, view = "bar", period = 300,
      metrics = [[{ expression = local.outcomes_search, id = "o1", label = "" }]]
    } },
    { type = "metric", x = 15, y = 7, width = 9, height = 7, properties = {
      title = "Outcome mix", region = var.region, view = "pie", period = 300,
      metrics = [[{ expression = local.outcomes_search, id = "o2", label = "" }]]
    } },

    # ============ DIALOG & MODEL (trends) ============
    { type = "text", x = 0, y = 14, width = 24, height = 1,
    properties = { markdown = "## Dialog & model" } },

    { type = "metric", x = 0, y = 15, width = 8, height = 6, properties = {
      title = "Dialog Lambda — duration (ms)", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        ["AWS/Lambda", "Duration", "FunctionName", local.fn, { stat = "p50", label = "p50" }],
        ["AWS/Lambda", "Duration", "FunctionName", local.fn, { stat = "p95", label = "p95" }],
        ["AWS/Lambda", "Duration", "FunctionName", local.fn, { stat = "Maximum", label = "max" }],
      ]
    } },
    { type = "metric", x = 8, y = 15, width = 8, height = 6, properties = {
      title = "Bedrock tokens per turn", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        [local.ns, "InputTokens", "Provider", var.provider_name, { stat = "Sum" }],
        [local.ns, "OutputTokens", "Provider", var.provider_name, { stat = "Sum" }],
      ]
    } },
    { type = "metric", x = 16, y = 15, width = 8, height = 6, properties = {
      title = "Safety — guardrail blocks / converse failures", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        [local.ns, "GuardrailBlocked", "Provider", var.provider_name, { stat = "Sum" }],
        [local.ns, "ConverseFailed", "Provider", var.provider_name, { stat = "Sum" }],
      ]
    } },

    # ============ ORCHESTRATION & INGRESS (trends) ============
    { type = "text", x = 0, y = 21, width = 24, height = 1,
    properties = { markdown = "## Orchestration & ingress" } },

    { type = "metric", x = 0, y = 22, width = 8, height = 6, properties = {
      title = "Step Functions — executions", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        ["AWS/States", "ExecutionsStarted", "StateMachineArn", local.arn, { stat = "Sum" }],
        ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", local.arn, { stat = "Sum" }],
        ["AWS/States", "ExecutionsFailed", "StateMachineArn", local.arn, { stat = "Sum" }],
        ["AWS/States", "ExecutionsTimedOut", "StateMachineArn", local.arn, { stat = "Sum" }],
      ]
    } },
    { type = "metric", x = 8, y = 22, width = 8, height = 6, properties = {
      title = "Ingress API — count & errors", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        ["AWS/ApiGateway", "Count", "ApiId", var.api_id, { stat = "Sum" }],
        ["AWS/ApiGateway", "4xx", "ApiId", var.api_id, { stat = "Sum" }],
        ["AWS/ApiGateway", "5xx", "ApiId", var.api_id, { stat = "Sum" }],
      ]
    } },
    { type = "metric", x = 16, y = 22, width = 8, height = 6, properties = {
      title = "Ingress API — latency (ms)", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p50", label = "p50" }],
        ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p95", label = "p95" }],
      ]
    } },

    { type = "metric", x = 0, y = 28, width = 8, height = 6, properties = {
      title = "EventBridge rule — invocations / failures", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        ["AWS/Events", "Invocations", "RuleName", var.rule_name, { stat = "Sum" }],
        ["AWS/Events", "FailedInvocations", "RuleName", var.rule_name, { stat = "Sum" }],
      ]
    } },
    { type = "metric", x = 8, y = 28, width = 8, height = 6, properties = {
      title = "Intake Lambda — invocations / errors", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        ["AWS/Lambda", "Invocations", "FunctionName", var.intake_fn, { stat = "Sum" }],
        ["AWS/Lambda", "Errors", "FunctionName", var.intake_fn, { stat = "Sum" }],
      ]
    } },
    { type = "metric", x = 16, y = 28, width = 8, height = 6, properties = {
      title = "Bedrock — invocations & latency", region = var.region, view = "timeSeries", period = 300,
      metrics = [
        [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"Invocations\"', 'Sum', 300)", id = "b1", label = "invocations" }],
        [{ expression = "SEARCH('{AWS/Bedrock,ModelId} MetricName=\"InvocationLatency\"', 'Average', 300)", id = "b2", label = "latency avg (ms)", yAxis = "right" }],
      ]
    } },

    # ============ DIAGNOSTICS ============
    { type = "text", x = 0, y = 34, width = 24, height = 1,
    properties = { markdown = "## Diagnostics" } },

    { type = "log", x = 0, y = 35, width = 24, height = 6, properties = {
      title = "Guardrail interventions & Converse failures (last 20)", region = var.region, view = "table",
      query = "SOURCE '${var.dialog_log_group}' | fields @timestamp, msg, action, error | filter msg = 'guardrail_intervened' or msg = 'converse_failed' | sort @timestamp desc | limit 20"
    } },
  ]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name_prefix
  dashboard_body = jsonencode({ widgets = local.widgets })
}

output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}
