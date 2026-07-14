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
    bucket         = "REPLACE_WITH_BOOTSTRAP_OUTPUT_state_bucket_name"
    key            = "meridian-pay/root/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "REPLACE_WITH_BOOTSTRAP_OUTPUT_lock_table_name"
    encrypt        = true
  }
}

# Default provider — targets the `security` account. Assumes the
# CI/local caller already has credentials for the security account
# (either directly, or via `aws configure` / assumed role locally).
provider "aws" {
  region = var.region

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
