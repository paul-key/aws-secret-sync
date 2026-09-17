output "writer_role_arn" {
  description = "Pass this to terraform/source as dest_role_arn."
  value       = aws_iam_role.writer.arn
}

output "writer_role_name" {
  value = aws_iam_role.writer.name
}

output "dest_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "expected_source_lambda_role_arn" {
  description = "IAM principal trusted by this role (create the source Lambda role with this ARN)."
  value       = local.source_lambda_role_arn
}
