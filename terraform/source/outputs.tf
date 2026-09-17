output "lambda_function_name" {
  value = aws_lambda_function.sync.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.sync.arn
}

output "lambda_role_arn" {
  description = "Must be trusted by terraform/dest (source_lambda_role_arn)."
  value       = aws_iam_role.lambda.arn
}

output "event_rule_arn" {
  value = aws_cloudwatch_event_rule.secrets.arn
}

output "cloudtrail_arn" {
  value = try(aws_cloudtrail.this[0].arn, null)
}
