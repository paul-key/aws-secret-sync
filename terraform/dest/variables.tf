variable "region" {
  description = "AWS region for destination Secrets Manager and IAM."
  type        = string
  default     = "us-east-1"
}

variable "secret_prefix" {
  description = "Secret name prefix to allow writes for (must match source)."
  type        = string
  default     = "prefix/"
}

variable "role_name" {
  description = "Name of the dest IAM role assumed by the source Lambda."
  type        = string
  default     = "secret-sync-writer"
}

variable "source_account_id" {
  description = "AWS account ID of the source (producer) account."
  type        = string
}

variable "source_lambda_role_name" {
  description = "Name of the source Lambda execution role. Used to build the trust principal when source_lambda_role_arn is empty."
  type        = string
  default     = "secret-sync-lambda"
}

variable "source_lambda_role_arn" {
  description = "ARN of the source Lambda execution role. If empty, trust arn:aws:iam::<source_account_id>:role/<source_lambda_role_name>."
  type        = string
  default     = ""
}

variable "external_id" {
  description = "STS ExternalId required when the source Lambda assumes this role (confused-deputy protection)."
  type        = string
  sensitive   = true
}
