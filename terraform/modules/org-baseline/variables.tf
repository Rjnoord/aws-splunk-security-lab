variable "region" {
  description = "Single allowed AWS region for the lab (cost + SCP-enforced)."
  type        = string
  default     = "us-east-1"
}

variable "org_id" {
  description = "AWS Organizations ID (o-xxxxxxxxxx). Required to attach SCPs to the root/OU."
  type        = string
}

variable "management_account_id" {
  description = "Account ID of the AWS Organizations management account."
  type        = string
}

variable "security_account_id" {
  description = "Account ID of the `security` member account (log archive, GuardDuty/Security Hub admin, Splunk)."
  type        = string
}

variable "workload_account_id" {
  description = "Account ID of the `workload` member account (payments app, attack surface)."
  type        = string
}

variable "scp_target_ids" {
  description = "OU or account IDs to attach the baseline SCPs to. Defaults to the org root if empty."
  type        = list(string)
  default     = []
}

variable "budget_limit_usd" {
  description = "Monthly budget threshold in USD before alerting (per PLAN.md Phase 0 DoD: $50/mo)."
  type        = number
  default     = 50
}

variable "budget_alert_email" {
  description = "Email address to receive SNS budget alarm notifications. Never commit a real value; set via terraform.tfvars (gitignored) or CI secret."
  type        = string
}

variable "budget_alert_thresholds_pct" {
  description = "Percent-of-budget thresholds that each trigger a separate notification (actual + forecasted)."
  type        = list(number)
  default     = [80, 100]
}
