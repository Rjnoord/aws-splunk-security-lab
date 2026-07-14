variable "region" {
  description = "AWS region for logging resources."
  type        = string
  default     = "us-east-1"
}

variable "security_account_id" {
  description = "Account ID of the `security` account that owns the log-archive bucket."
  type        = string
}

variable "workload_account_id" {
  description = "Account ID of the `workload` account whose activity is logged (org trail covers it automatically, but VPC FL/ALB/WAF delivery needs this for bucket policy scoping)."
  type        = string
}

variable "org_id" {
  description = "AWS Organizations ID, used to scope the org-trail bucket policy to only this org's trails."
  type        = string
}

variable "log_archive_bucket_name" {
  description = "Globally-unique S3 bucket name for the centralized log archive."
  type        = string
}

variable "object_lock_retention_days" {
  description = "Object Lock (COMPLIANCE mode) minimum retention in days for the log archive — tamper-evidence for audit evidence per ARCHITECTURE.md."
  type        = number
  default     = 400
}

variable "cloudtrail_name" {
  description = "Name of the AWS Organizations management (org-level) CloudTrail trail."
  type        = string
  default     = "meridian-pay-org-trail"
}

variable "enable_vpc_flow_logs" {
  description = "Toggle VPC Flow Logs delivery. Off by default until the workload VPC exists (later phase)."
  type        = bool
  default     = false
}

variable "workload_vpc_id" {
  description = "Workload VPC ID to attach Flow Logs to. Required only when enable_vpc_flow_logs = true."
  type        = string
  default     = null
}

variable "enable_alb_waf_logs" {
  description = "Toggle ALB access log + WAF log delivery to S3. Off by default until the workload ALB/WAF exist (later phase)."
  type        = bool
  default     = false
}

variable "enable_aws_config" {
  description = "Toggle the AWS Config recorder + delivery channel. Off by default: AWS Config does not support delivering to an S3 bucket with Object Lock + default retention enabled (which the log-archive bucket has, deliberately, for CloudTrail tamper-evidence). Revisit with a separate non-Object-Lock bucket for Config if/when this is needed."
  type        = bool
  default     = false
}

variable "guardduty_member_account_ids" {
  description = "Member account IDs (e.g. workload) to invite under GuardDuty delegated administration in the security account."
  type        = list(string)
  default     = []
}

variable "guardduty_member_emails" {
  description = "Map of account_id => root email, required by aws_guardduty_member for invitations."
  type        = map(string)
  default     = {}
}
