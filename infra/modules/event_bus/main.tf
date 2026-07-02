# Custom EventBridge bus — RepairOrderCompleted in, Call* events out (§8).

variable "name_prefix" {
  type = string
}

resource "aws_cloudwatch_event_bus" "main" {
  name = "${var.name_prefix}-bus"
}

output "bus_name" {
  value = aws_cloudwatch_event_bus.main.name
}

output "bus_arn" {
  value = aws_cloudwatch_event_bus.main.arn
}
