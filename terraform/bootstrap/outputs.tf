output "state_bucket_name" {
  description = "Paste into terraform/provider.tf backend \"s3\" block as `bucket`."
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "Paste into terraform/provider.tf backend \"s3\" block as `dynamodb_table`."
  value       = aws_dynamodb_table.tflock.name
}

output "tfstate_kms_key_arn" {
  description = "KMS CMK used for state bucket encryption."
  value       = aws_kms_key.tfstate.arn
}

output "github_actions_plan_role_arn" {
  description = "Paste into the GitHub repo variable AWS_OIDC_PLAN_ROLE_ARN used by .github/workflows/terraform.yml (PR/plan job). Read-only permissions; trusted only for pull_request-triggered runs."
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_actions_apply_role_arn" {
  description = "Paste into the GitHub repo variable AWS_OIDC_APPLY_ROLE_ARN used by .github/workflows/terraform.yml (main-push apply job). PowerUserAccess + scoped IAM/Organizations permissions; trusted only for runs under the `production` GitHub Environment."
  value       = aws_iam_role.github_actions_apply.arn
}
