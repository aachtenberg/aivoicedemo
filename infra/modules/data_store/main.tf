# DynamoDB single table (jobs/attempts/call-event log — §8) + S3 for recordings.

variable "name_prefix" {
  type = string
}

resource "aws_dynamodb_table" "main" {
  name         = "${var.name_prefix}-calls"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "recordings" {
  bucket        = "${var.name_prefix}-recordings-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "recordings" {
  bucket                  = aws_s3_bucket.recordings.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "table_name" {
  value = aws_dynamodb_table.main.name
}

output "table_arn" {
  value = aws_dynamodb_table.main.arn
}

output "bucket_name" {
  value = aws_s3_bucket.recordings.bucket
}
