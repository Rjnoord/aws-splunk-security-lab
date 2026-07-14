variable "region" {
  description = "AWS region for the bootstrap resources (state bucket, lock table, OIDC provider/role)."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally-unique name for the Terraform state S3 bucket. Include account ID or a random suffix."
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locking."
  type        = string
  default     = "meridian-pay-tfstate-lock"
}

variable "github_org" {
  description = "GitHub org/user that owns this repo (used to scope the OIDC trust policy)."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo name (used to scope the OIDC trust policy)."
  type        = string
  default     = "aws-splunk-security-lab"
}
