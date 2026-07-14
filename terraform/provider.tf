terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Backend values below are filled in AFTER running
  # `terraform/bootstrap` once by hand — see terraform/README.md.
  # Left with placeholder values so `terraform init -backend=false`
  # works for local validation without real infrastructure.
  backend "s3" {
    bucket         = "meridian-pay-tfstate-448842988605"
    key            = "meridian-pay/root/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "meridian-pay-tfstate-lock"
    encrypt        = true
  }
}

# Default provider — targets the `security` account. Two operating
# modes, selected by `var.security_role_arn`:
#
#   (a) Ambient credentials ARE security-account credentials directly
#       (e.g. an `aws configure` profile or assumed role that is
#       already a security-account principal). Leave
#       security_role_arn null — the dynamic assume_role block below
#       is skipped and the provider uses ambient credentials as-is.
#
#   (b) Ambient credentials are management-account credentials (this
#       is the case for both CI's OIDC-assumed `github_actions_apply`
#       role and a local operator's IAM user — both live in the
#       management account per the bootstrap trust model). Set
#       security_role_arn to the security-account role to assume
#       (AWS's auto-created `OrganizationAccountAccessRole` unless a
#       purpose-built role exists) so this provider actually operates
#       against the security account instead of silently creating
#       resources in management.
provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.security_role_arn != null ? [var.security_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "meridian-pay-terraform-security"
    }
  }

  default_tags {
    tags = {
      Project     = "meridian-pay-security-lab"
      ManagedBy   = "terraform"
      Environment = "security"
    }
  }
}

# Management-account alias — required for org-baseline (SCPs live
# at the Organizations level) and for the org-level CloudTrail
# trail resource in the logging module.
#
# Pattern: the management account has an IAM role
# (e.g. OrganizationAccountAccessRole or a purpose-built
# "terraform-org-admin" role) that the security-account CI
# principal is allowed to assume. Set var.management_role_arn to
# use it; leave null to run with the default provider's identity
# (e.g. when applying locally as an Organizations management-account
# user directly).
provider "aws" {
  alias  = "management"
  region = var.region

  dynamic "assume_role" {
    for_each = var.management_role_arn != null ? [var.management_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "meridian-pay-terraform-org-baseline"
    }
  }

  default_tags {
    tags = {
      Project     = "meridian-pay-security-lab"
      ManagedBy   = "terraform"
      Environment = "management"
    }
  }
}
