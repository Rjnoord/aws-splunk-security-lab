############################################################
# Bootstrap — run ONCE, by hand, with local AWS credentials
# before any other Terraform in this repo can run.
#
# Chicken-and-egg problem this solves:
#   1. The root config's `backend "s3"` block needs an S3 bucket
#      + DynamoDB table to already exist — Terraform cannot
#      create the backend it is about to store its own state in.
#   2. GitHub Actions needs an IAM role it can assume via OIDC
#      *before* it can run any Terraform — that role can't be
#      created by the same CI pipeline it's meant to authorize.
#
# This config has NO remote backend (local state only, on
# purpose) and is applied exactly once per environment/account.
# After it succeeds, copy the outputs into:
#   - terraform/provider.tf (backend "s3" block)
#   - GitHub repo variables (AWS_OIDC_PLAN_ROLE_ARN,
#     AWS_OIDC_APPLY_ROLE_ARN, etc.)
# then never touch this directory again unless you're rotating
# the backend or the OIDC trust.
############################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Intentionally local — see header comment.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "meridian-pay-security-lab"
      ManagedBy   = "terraform-bootstrap"
      Environment = "security"
    }
  }
}

# ---------------------------------------------------------------
# Terraform state backend: S3 bucket (versioned, KMS-encrypted,
# public-access blocked) + DynamoDB lock table.
# ---------------------------------------------------------------

resource "aws_kms_key" "tfstate" {
  description             = "CMK for Terraform state bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/meridian-pay-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # Never destroy state accidentally via `terraform destroy`.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tfstate_deny_insecure_transport" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_dynamodb_table" "tflock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.tfstate.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

# ---------------------------------------------------------------
# GitHub Actions OIDC provider + TWO roles, split by privilege:
#
#   - "plan" role: assumable from `pull_request`-triggered workflow
#     runs (any branch/fork PR against this repo). Read-only/plan
#     permissions ONLY — no IAM, no Organizations, no write access.
#     GitHub exposes repo *variables* (like the plan role's ARN) to
#     pull_request-triggered workflows even from forks, so this role
#     must never be able to mutate anything.
#
#   - "apply" role: trusted ONLY for the `sub` claim GitHub emits
#     when a workflow job declares `environment: production` — i.e.
#     `repo:ORG/REPO:environment:production`. That claim is only
#     present on runs of jobs bound to the `production` GitHub
#     Environment, which requires human reviewer approval. This ties
#     the human-approval gate to an IAM-enforced trust condition, not
#     just a workflow-level `if:` check. Carries write/PowerUser +
#     the scoped IAM/Organizations permissions actually needed to
#     apply org-baseline/logging.
# ---------------------------------------------------------------

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# ---- Plan role: pull_request events only, read-only permissions ----

data "aws_iam_policy_document" "github_oidc_trust_plan" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only `pull_request`-triggered workflow runs on this exact repo.
    # This is what's exposed to forked-repo PRs, so it must stay
    # read-only (see policy attachment below).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_actions_plan" {
  name               = "meridian-pay-github-actions-plan"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust_plan.json
}

# ReadOnlyAccess is broad-read (covers every service, no write/IAM
# actions). Sufficient for `terraform plan` to evaluate diffs against
# real state without granting any ability to create/modify/delete.
resource "aws_iam_role_policy_attachment" "github_actions_plan_readonly" {
  role       = aws_iam_role.github_actions_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ---- Apply role: gated on the `production` GitHub Environment ----

data "aws_iam_policy_document" "github_oidc_trust_apply" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only jobs running under the `production` GitHub Environment
    # (required-reviewer approval enforced by GitHub) carry this
    # `sub` claim — StringEquals (not StringLike) so no wildcard
    # ever matches a non-approved run.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "github_actions_apply" {
  name               = "meridian-pay-github-actions-apply"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_trust_apply.json
}

# Deliberately broad-ish PowerUser-style policy for lab convenience,
# scoped down from AdministratorAccess. In a real environment this
# would be a hand-built least-privilege policy per resource type;
# noted here as a known trade-off for a personal lab. This is the
# only role PowerUserAccess is attached to — the plan role never
# gets it.
resource "aws_iam_role_policy_attachment" "github_actions_apply_poweruser" {
  role       = aws_iam_role.github_actions_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess excludes IAM and Organizations; org-baseline/logging
# modules need to manage a small, fixed set of IAM roles (SSM instance
# profile, AWS Config service role) and Organizations SCPs/delegated-
# admin registrations. Scoped to:
#   - IAM: only roles matching this project's naming convention
#     (meridian-pay-*, per modules/org-baseline and modules/logging),
#     NOT "*" — this closes the CreateRole+AttachRolePolicy+PassRole
#     privilege-escalation chain that existed when Resource was "*".
#     Further split below by role/action so that PutRolePolicy (inline
#     policy authoring) is only granted on meridian-pay-aws-config —
#     the only role modules/logging/main.tf actually calls
#     PutRolePolicy on (aws_iam_role_policy.config_s3_write).
#     AttachRolePolicy/DetachRolePolicy are likewise split out of the
#     role-wide statement into their own per-role statements, each
#     pinned with an `iam:PolicyARN` condition to the exact single
#     managed policy that role is ever attached (AmazonSSMManagedInstanceCore
#     for meridian-pay-ssm-managed-instance, AWS_ConfigRole for
#     meridian-pay-aws-config). This closes the escalation path where
#     the apply role could attach (or inline, via PutRolePolicy) an
#     admin-equivalent policy onto either role, launch an EC2 instance
#     with the SSM role's instance profile via PowerUserAccess, and
#     pull admin creds from instance metadata — no policy ARN other
#     than the one each role legitimately uses can ever be attached.
#     PassRole is also split per-role and constrained with
#     iam:PassedToService so it can only be redeemed by the service
#     that actually consumes each role (EC2 for the SSM role, Config
#     for the Config role).
#     Instance-profile actions (Create/Delete/GetInstanceProfile) act
#     on the `instance-profile/*` ARN namespace, not `role/*` — they
#     get their own statement scoped to the one instance profile this
#     repo creates (meridian-pay-ssm-managed-instance, org-baseline).
#     AddRoleToInstanceProfile/RemoveRoleFromInstanceProfile operate on
#     both a role ARN and an instance-profile ARN simultaneously, so
#     that statement's Resource list includes both.
#   - Organizations: an explicit action list (SCP CRUD/attach + the
#     delegated-admin registration calls GuardDuty/Security Hub
#     delegation needs), not "organizations:*". ListAccounts removed —
#     nothing in org-baseline or logging calls it; org lookups go
#     through the aws_organizations_organization data source
#     (DescribeOrganization/ListRoots) instead.
resource "aws_iam_role_policy" "github_actions_apply_iam_scoped" {
  name = "iam-scoped-for-terraform"
  role = aws_iam_role.github_actions_apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IamRoleManagementScopedToProjectRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:TagRole",
          "iam:UntagRole",
        ]
        # Matches every role this repo's modules actually create:
        # meridian-pay-ssm-managed-instance (org-baseline),
        # meridian-pay-aws-config (logging). Deliberately NOT "*".
        # AttachRolePolicy/DetachRolePolicy and inline-policy-write
        # actions are intentionally excluded here — see the
        # Iam*AttachDetach* and IamInlinePolicyWriteScopedToConfigRole
        # statements below, each scoped to a single role + single
        # policy ARN.
        Resource = "arn:aws:iam::*:role/meridian-pay-*"
      },
      {
        Sid    = "IamInlinePolicyWriteScopedToConfigRole"
        Effect = "Allow"
        Action = [
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
        ]
        # Only meridian-pay-aws-config receives an inline policy
        # (aws_iam_role_policy.config_s3_write in modules/logging).
        # meridian-pay-ssm-managed-instance never gets PutRolePolicy —
        # closes the inline-admin-policy escalation path via that role.
        Resource = "arn:aws:iam::*:role/meridian-pay-aws-config"
      },
      {
        Sid    = "IamAttachDetachManagedPolicyScopedToSsmRole"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        # Only meridian-pay-ssm-managed-instance is ever attached, and
        # only ever the one managed policy below
        # (aws_iam_role_policy_attachment.ssm_core in
        # modules/org-baseline). The iam:PolicyARN condition pins this
        # so the apply role can never attach any other policy (e.g.
        # AdministratorAccess) to this role, closing the
        # attach-admin-then-PassRole-to-EC2 escalation path.
        Resource = "arn:aws:iam::*:role/meridian-pay-ssm-managed-instance"
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
          }
        }
      },
      {
        Sid    = "IamAttachDetachManagedPolicyScopedToConfigRole"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        # Only meridian-pay-aws-config is ever attached, and only ever
        # the one managed policy below
        # (aws_iam_role_policy_attachment.config_managed in
        # modules/logging). Same PolicyARN-pinning pattern as the SSM
        # role above — no other policy can be attached via this role.
        Resource = "arn:aws:iam::*:role/meridian-pay-aws-config"
        Condition = {
          ArnEquals = {
            "iam:PolicyARN" = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
          }
        }
      },
      {
        Sid    = "IamInstanceProfileManagementScopedToSsmInstanceProfile"
        Effect = "Allow"
        Action = [
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
        ]
        # These actions operate on the instance-profile/* ARN
        # namespace, not role/* — a `role/meridian-pay-*` resource
        # would never match and every call would AccessDenied at
        # apply time. The only instance profile this repo creates is
        # aws_iam_instance_profile.ssm_managed (modules/org-baseline).
        Resource = "arn:aws:iam::*:instance-profile/meridian-pay-ssm-managed-instance"
      },
      {
        Sid    = "IamAddRemoveRoleInstanceProfileScopedToSsm"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
        ]
        # IAM evaluates these actions against BOTH a role ARN and an
        # instance-profile ARN, so both must be present in Resource.
        # Scoped to the one role/instance-profile pair this repo
        # creates (meridian-pay-ssm-managed-instance in both
        # namespaces, modules/org-baseline).
        Resource = [
          "arn:aws:iam::*:role/meridian-pay-ssm-managed-instance",
          "arn:aws:iam::*:instance-profile/meridian-pay-ssm-managed-instance",
        ]
      },
      {
        Sid      = "PassRoleSsmManagedInstanceToEc2Only"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/meridian-pay-ssm-managed-instance"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid      = "PassRoleAwsConfigToConfigServiceOnly"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::*:role/meridian-pay-aws-config"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "config.amazonaws.com"
          }
        }
      },
      {
        Sid    = "OrganizationsScpAndDelegatedAdmin"
        Effect = "Allow"
        Action = [
          # SCP lifecycle (org-baseline: deny-leave-region,
          # deny-disable-cloudtrail, deny-disable-guardduty).
          "organizations:CreatePolicy",
          "organizations:UpdatePolicy",
          "organizations:DeletePolicy",
          "organizations:AttachPolicy",
          "organizations:DetachPolicy",
          "organizations:DescribePolicy",
          "organizations:ListPolicies",
          "organizations:ListPoliciesForTarget",
          "organizations:ListTargetsForPolicy",
          "organizations:TagResource",
          "organizations:UntagResource",
          "organizations:ListTagsForResource",
          # Read-only org lookups (aws_organizations_organization data
          # source, SCP root/target resolution).
          "organizations:DescribeOrganization",
          "organizations:ListRoots",
          # Delegated-admin registration needed by
          # aws_guardduty_organization_admin_account and
          # aws_securityhub_organization_admin_account (logging module).
          "organizations:EnableAWSServiceAccess",
          "organizations:RegisterDelegatedAdministrator",
          "organizations:DeregisterDelegatedAdministrator",
          "organizations:ListDelegatedAdministrators",
          "organizations:ListDelegatedServicesForAccount",
        ]
        Resource = "*"
      },
      {
        # Both CI's OIDC-assumed apply role and the local operator's
        # IAM user authenticate as management-account principals (per
        # the bootstrap trust model above), but the root config's
        # default provider (terraform/provider.tf) is meant to operate
        # AS the security account. Without this permission, that
        # provider's dynamic assume_role block would fail with
        # AccessDenied the moment security_role_arn is set, since the
        # calling principal wouldn't be allowed to assume into that
        # account at all. AWS auto-creates OrganizationAccountAccessRole
        # in every member account when the account is created via
        # Organizations, so it's available without any additional
        # per-account setup.
        #
        # Deliberately NOT granting workload_account_id here yet — no
        # Terraform module targets the workload account today, so
        # there's no consumer for that grant. Add it (and the
        # corresponding provider wiring) in the same change that
        # introduces the first workload-targeting module, so the grant
        # and its consumer are reviewed together instead of sitting as
        # unused standing privilege. (Flagged by sentinel review.)
        #
        # Also tracked as tech debt: OrganizationAccountAccessRole is
        # AWS's full-admin-equivalent default role. Using it as the
        # cross-account bridge is the pragmatic lab choice today, but
        # the long-term target should be a purpose-built least-privilege
        # role in the security account scoped to what org-baseline/
        # logging/ingestion-sqs actually need (KMS, S3, GuardDuty,
        # Security Hub, Config, CloudTrail, SQS/SNS) — this is the one
        # place in this file that doesn't follow the no-wildcard,
        # scoped-admin-paths philosophy used everywhere else.
        Sid      = "AssumeRoleIntoSecurityAccount"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::${var.security_account_id}:role/OrganizationAccountAccessRole"
      }
    ]
  })
}
