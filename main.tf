resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

locals {
  name = "s3-datadog-logs-${random_string.suffix.result}"
}

resource "aws_cloudwatch_event_connection" "datadog" {
  name               = local.name
  authorization_type = "API_KEY"


  auth_parameters {
    api_key {
      key   = "DD-API-KEY"
      value = var.datadog_api_key
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "datadog" {
  name                             = local.name
  description                      = "API destination for Datadog"
  invocation_endpoint              = "https://http-intake.logs.datadoghq.com/api/v2/logs"
  http_method                      = "POST"
  connection_arn                   = aws_cloudwatch_event_connection.datadog.arn
  invocation_rate_limit_per_second = 300
}

resource "aws_cloudwatch_event_rule" "datadog" {
  name = local.name

  event_pattern = jsonencode(
    {
      source = ["aws.s3"]
    }
  )

  state = "ENABLED"
}

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-dlq"
  delay_seconds             = 60
  max_message_size          = 262144
  message_retention_seconds = 345600
  receive_wait_time_seconds = 10
}

resource "aws_iam_role" "invoke_api" {
  name = local.name

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "events.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_policy" "invoke_api" {
  name = "${local.name}-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "events:InvokeApiDestination",
        Effect   = "Allow",
        Resource = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:api-destination/${local.name}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "invoke_api" {
  role       = aws_iam_role.invoke_api.name
  policy_arn = aws_iam_policy.invoke_api.arn
}


resource "aws_cloudwatch_event_target" "datadog" {
  arn = aws_cloudwatch_event_api_destination.datadog.arn

  role_arn  = aws_iam_role.invoke_api.arn
  rule      = aws_cloudwatch_event_rule.datadog.name
  target_id = "SendToApiDestination"

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }
}

resource "aws_s3_bucket" "example" {
  bucket = local.name

  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "example" {
  bucket = aws_s3_bucket.example.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "example" {
  bucket = aws_s3_bucket.example.id
  acl    = "private"

  depends_on = [
    aws_s3_bucket_ownership_controls.example
  ]
}

resource "aws_s3_bucket_notification" "example" {
  bucket      = aws_s3_bucket.example.id
  eventbridge = true
}

resource "aws_s3_object" "example" {
  bucket = aws_s3_bucket.example.bucket
  key    = "files/demo.txt"
  source = "${path.module}/external/demo.txt"

  depends_on = [
    aws_cloudwatch_event_rule.datadog,
    aws_cloudwatch_event_api_destination.datadog
  ]
}
