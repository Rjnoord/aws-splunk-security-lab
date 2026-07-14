variable "region" {
  description = "AWS region for ingestion resources."
  type        = string
  default     = "us-east-1"
}

variable "security_account_id" {
  description = "Account ID of the `security` account that owns the log-archive bucket and this ingestion pipeline."
  type        = string
}

variable "log_archive_bucket_name" {
  description = "S3 bucket name of the centralized log archive (from module.logging), used for the S3->SNS notification and IAM scoping."
  type        = string
}

variable "log_archive_bucket_arn" {
  description = "ARN of the centralized log-archive bucket (from module.logging)."
  type        = string
}

variable "log_archive_kms_key_arn" {
  description = "CMK ARN used to encrypt log-archive objects (from module.logging). Granted to the Splunk puller IAM user for kms:Decrypt/DescribeKey only — this module does not modify the key policy itself."
  type        = string
}

variable "sqs_visibility_timeout_seconds" {
  description = "Visibility timeout for the main S3-events SQS queue."
  type        = number
  default     = 300
}

variable "dlq_max_receive_count" {
  description = "Number of failed receives before a message is moved to the dead-letter queue."
  type        = number
  default     = 5
}

variable "name_prefix" {
  description = "Naming prefix applied to all resources created by this module."
  type        = string
  default     = "meridian-pay"
}

variable "notification_filter_prefix" {
  description = "S3 key prefix filter for the bucket notification (only CloudTrail's AWSLogs/ prefix is routed for Phase 3 Pattern A)."
  type        = string
  default     = "AWSLogs/"
}
