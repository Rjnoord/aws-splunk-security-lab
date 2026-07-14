variable "region" {
  description = "Single approved AWS region for the whole lab (also enforced by the deny-leave-region SCP)."
  type        = string
  default     = "us-east-1"
}

variable "org_id" {
  description = "AWS Organizations ID (o-xxxxxxxxxx)."
  type        = string
}

variable "management_account_id" {
  description = "Account ID of the AWS Organizations management account."
  type        = string
}

variable "security_account_id" {
  description = "Account ID of the `security` member account."
  type        = string
}

variable "workload_account_id" {
  description = "Account ID of the `workload` member account."
  type        = string
}

variable "management_role_arn" {
  description = "IAM role ARN in the management account that the security-account/CI principal can assume for org-level actions (SCPs, org CloudTrail trail). Null to use the default provider identity directly (e.g. running locally as a management-account user)."
  type        = string
  default     = null
}

variable "security_role_arn" {
  description = "ARN of a role in the security account to assume when ambient credentials are for a different account (e.g. management). Null to use ambient credentials directly (when already running as a security-account principal)."
  type        = string
  default     = null
}

variable "budget_alert_email" {
  description = "Email to receive the $50/mo AWS Budgets SNS alert. Set via terraform.tfvars (gitignored) or CI secret — never commit a real address."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget alarm threshold in USD."
  type        = number
  default     = 50
}

variable "log_archive_bucket_name" {
  description = "Globally-unique S3 bucket name for the centralized log archive. Recommend including the security account ID for uniqueness, e.g. meridian-pay-log-archive-123456789012."
  type        = string
}

variable "enable_vpc_flow_logs" {
  description = "Toggle VPC Flow Logs delivery. Leave false until the workload VPC module (later phase) exists."
  type        = bool
  default     = false
}

variable "workload_vpc_id" {
  description = "Workload VPC ID, required only once enable_vpc_flow_logs = true."
  type        = string
  default     = null
}

variable "guardduty_member_account_ids" {
  description = "Member accounts (typically [workload_account_id]) to invite under GuardDuty delegated administration."
  type        = list(string)
  default     = []
}

variable "guardduty_member_emails" {
  description = "Map of account_id => root email for GuardDuty member invitations."
  type        = map(string)
  default     = {}
}
