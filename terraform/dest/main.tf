data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  source_lambda_role_arn = var.source_lambda_role_arn != "" ? var.source_lambda_role_arn : "arn:${data.aws_partition.current.partition}:iam::${var.source_account_id}:role/${var.source_lambda_role_name}"

  dest_secret_arn = "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}*"
}

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "AssumeFromSourceLambda"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["${local.source_lambda_role_arn}"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

data "aws_iam_policy_document" "secrets" {
  statement {
    sid    = "CreateUpdateAndDeletePrefixedSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:RestoreSecret",
    ]
    resources = [local.dest_secret_arn]
  }
}

resource "aws_iam_role" "writer" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy" "writer_secrets" {
  name   = "secret-sync-put"
  role   = aws_iam_role.writer.id
  policy = data.aws_iam_policy_document.secrets.json
}
