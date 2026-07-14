############################################################
# org-baseline
# Phase 0 — guardrails that must exist before any workload
# resources are created: SCPs, budget alerting, and the
# least-privilege IAM plumbing for SSM-only EC2 admin access.
#
# NOTE: SCPs require this module to run with credentials in
# the AWS Organizations *management* account. GuardDuty/Config/
# Security Hub delegated-admin wiring lives in the `logging`
# module (applied from the `security` account).
############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------
# SCP baseline
# ---------------------------------------------------------------

data "aws_organizations_organization" "this" {}

locals {
  # Fall back to the org root if no explicit OU/account targets given.
  scp_targets = length(var.scp_target_ids) > 0 ? var.scp_target_ids : [data.aws_organizations_organization.this.roots[0].id]
}

resource "aws_organizations_policy" "deny_leave_region" {
  name        = "deny-leave-region"
  description = "Deny all actions outside the approved region, except a short list of always-global services."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyOutsideApprovedRegion"
        Effect = "Deny"
        NotAction = [
          # Global / region-agnostic services that must remain usable
          # from any endpoint (IAM, Organizations, Route53, CloudFront,
          # STS, Support, Billing, and the handful of global-only APIs).
          "iam:*",
          "organizations:*",
          "route53:*",
          "route53domains:*",
          "cloudfront:*",
          "sts:*",
          "support:*",
          "budgets:*",
          "ce:*",
          "trustedadvisor:*",
          "waf:*",
          "wafregional:*",
          "shield:*",
          "a4b:*",
          "chime:*",
          "globalaccelerator:*",
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = [var.region]
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy" "deny_disable_cloudtrail" {
  name        = "deny-disable-cloudtrail"
  description = "Deny actions that would stop, delete, or tamper with the org CloudTrail trail."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyCloudTrailTamper"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging",
          "cloudtrail:DeleteTrail",
          "cloudtrail:UpdateTrail",
          "cloudtrail:PutEventSelectors",
          "cloudtrail:RemoveTags",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy" "deny_disable_guardduty" {
  name        = "deny-disable-guardduty"
  description = "Deny actions that would disable GuardDuty or remove the delegated administrator relationship."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyGuardDutyTamper"
        Effect = "Deny"
        Action = [
          "guardduty:DeleteDetector",
          "guardduty:DisassociateFromMasterAccount",
          "guardduty:DisassociateMembers",
          "guardduty:StopMonitoringMembers",
          "guardduty:UpdateDetector",
          "guardduty:DeleteMembers",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_region" {
  for_each  = toset(local.scp_targets)
  policy_id = aws_organizations_policy.deny_leave_region.id
  target_id = each.value
}

resource "aws_organizations_policy_attachment" "deny_disable_cloudtrail" {
  for_each  = toset(local.scp_targets)
  policy_id = aws_organizations_policy.deny_disable_cloudtrail.id
  target_id = each.value
}

resource "aws_organizations_policy_attachment" "deny_disable_guardduty" {
  for_each  = toset(local.scp_targets)
  policy_id = aws_organizations_policy.deny_disable_guardduty.id
  target_id = each.value
}

# ---------------------------------------------------------------
# Budget alarm — $50/mo -> SNS -> email
# ---------------------------------------------------------------

resource "aws_sns_topic" "budget_alerts" {
  name = "meridian-pay-budget-alerts"
}

resource "aws_sns_topic_subscription" "budget_email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "meridian-pay-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.budget_alert_thresholds_pct
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
    }
  }

  # Extra early-warning notification on forecasted (not just actual) spend.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.budget_alerts.arn]
  }
}

# ---------------------------------------------------------------
# SSM Session Manager — least-privilege instance role.
# No SSH keys, no bastion, no inbound port 22 anywhere in the lab.
# Attach `aws_iam_instance_profile.ssm_managed.name` to any EC2
# instance (Splunk in Phase 2, app hosts in later phases).
# ---------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_managed" {
  name               = "meridian-pay-ssm-managed-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# AWS-managed policy that grants exactly the permissions SSM Agent
# needs (Session Manager, patch/inventory) — no broader EC2 access.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_managed.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_managed" {
  name = "meridian-pay-ssm-managed-instance"
  role = aws_iam_role.ssm_managed.name
}
