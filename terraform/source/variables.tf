variable "region" {
  description = "AWS region for the Lambda, EventBridge rule, and source Secrets Manager."
  type        = string
  default     = "us-east-1"
}

variable "dest_region" {
  description = "Region of destination Secrets Manager (usually the same as region)."
  type        = string
  default     = ""
}

variable "secret_prefix" {
  description = "Only secrets whose name starts with this prefix are synced."
  type        = string
  default     = ""
}

variable "lambda_function_name" {
  type    = string
  default = "secret-sync"
}

variable "lambda_role_name" {
  description = "Must match dest trust (source_lambda_role_name) unless dest uses an explicit source_lambda_role_arn."
  type        = string
  default     = "secret-sync-lambda"
}

variable "dest_role_arn" {
  description = "ARN of the destination writer role (terraform/dest output writer_role_arn)."
  type        = string
}

variable "external_id" {
  description = "Same STS ExternalId configured on the destination writer role."
  type        = string
  sensitive   = true
}

variable "create_cloudtrail" {
  description = "If true, create a management-event CloudTrail trail (required for EventBridge AWS API Call via CloudTrail if none exists)."
  type        = bool
  default     = false
}

variable "cloudtrail_name" {
  type    = string
  default = "secret-sync-trail"
}

variable "cloudtrail_bucket_name" {
  description = "S3 bucket name for the optional trail. Leave empty to generate one."
  type        = string
  default     = ""
}
