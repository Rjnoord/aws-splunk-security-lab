output "budget_sns_topic_arn" {
  description = "SNS topic ARN used for budget alerts (reusable by other modules, e.g. GuardDuty finding notifications)."
  value       = aws_sns_topic.budget_alerts.arn
}

output "ssm_instance_profile_name" {
  description = "Attach to any EC2 instance for SSM Session Manager-only admin access."
  value       = aws_iam_instance_profile.ssm_managed.name
}

output "ssm_instance_role_arn" {
  description = "IAM role ARN backing the SSM instance profile."
  value       = aws_iam_role.ssm_managed.arn
}

output "scp_ids" {
  description = "IDs of the baseline SCPs created (for reference/verification)."
  value = {
    deny_leave_region       = aws_organizations_policy.deny_leave_region.id
    deny_disable_cloudtrail = aws_organizations_policy.deny_disable_cloudtrail.id
    deny_disable_guardduty  = aws_organizations_policy.deny_disable_guardduty.id
  }
}
