data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  dest_region     = var.dest_region != "" ? var.dest_region : var.region
  source_secret_arn = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}*"
  trail_bucket    = var.cloudtrail_bucket_name != "" ? var.cloudtrail_bucket_name : "secret-sync-cloudtrail-${data.aws_caller_identity.current.account_id}-${var.region}"
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../../src/sync_secrets.py"
  output_path = "${path.module}/sync_secrets.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid    = "ReadSourcePrefixedSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [local.source_secret_arn]
  }

  statement {
    sid       = "AssumeDestWriter"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [var.dest_role_arn]
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
  }
}

resource "aws_iam_role" "lambda" {
  name               = var.lambda_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy" "lambda" {
  name   = "secret-sync"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "sync" {
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  handler          = "sync_secrets.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      SECRET_PREFIX = var.secret_prefix
      DEST_ROLE_ARN = var.dest_role_arn
      EXTERNAL_ID   = var.external_id
      DEST_REGION   = local.dest_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}

resource "aws_cloudwatch_event_rule" "secrets" {
  name        = "${var.lambda_function_name}-secretsmanager"
  description = "Secrets Manager CloudTrail API calls for cross-account secret sync"

  event_pattern = jsonencode({
    source        = ["aws.secretsmanager"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["secretsmanager.amazonaws.com"]
      eventName = [
        "CreateSecret",
        "PutSecretValue",
        "UpdateSecret",
        "RestoreSecret",
        "DeleteSecret",
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule = aws_cloudwatch_event_rule.secrets.name
  arn  = aws_lambda_function.sync.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.secrets.arn
}
