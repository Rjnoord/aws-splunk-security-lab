############################################################
# logging
# Phase 1 — centralized, tamper-evident log archive + the AWS
# detection services (GuardDuty, Security Hub, Config).
#
# Run with credentials in the `security` account. The org-level
# CloudTrail trail itself must be created from the Organizations
# *management* account (aws_cloudtrail with is_organization_trail
# requires the management-account provider) — see root main.tf
# for the provider alias wiring.
############################################################

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.management]
    }
  }
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------
# KMS CMK for all log-archive encryption (CloudTrail, S3, Config).
# ---------------------------------------------------------------

resource "aws_kms_key" "log_archive" {
  description             = "CMK for the Meridian Pay centralized log archive (CloudTrail, VPC FL, ALB/WAF)."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudTrailToEncrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceOrgID" = var.org_id
          }
        }
      },
      {
        Sid       = "AllowCloudTrailToDescribe"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:DescribeKey"
        Resource  = "*"
      },
      {
        Sid    = "AllowLogDeliveryServices"
        Effect = "Allow"
        Principal = {
          Service = [
            "delivery.logs.amazonaws.com",
            "config.amazonaws.com",
          ]
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "log_archive" {
  name          = "alias/meridian-pay-log-archive"
  target_key_id = aws_kms_key.log_archive.key_id
}

# ---------------------------------------------------------------
# Log-archive S3 bucket: SSE-KMS, Block Public Access, Object
# Lock (COMPLIANCE mode, tamper-evidence for audit evidence),
# deny-non-TLS bucket policy.
# ---------------------------------------------------------------

resource "aws_s3_bucket" "log_archive" {
  bucket = var.log_archive_bucket_name

  # Object Lock can only be enabled at bucket creation time.
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

# Object Lock requires versioning to be enabled.
resource "aws_s3_bucket_versioning" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.log_archive]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.log_archive.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: keep raw objects for the Object Lock retention window,
# then let CloudTrail's own event-selector-driven volume be managed
# by index retention in Splunk (S3 stays as long-term cold evidence).
resource "aws_s3_bucket_lifecycle_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  rule {
    id     = "transition-to-ia-then-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

data "aws_iam_policy_document" "log_archive_bucket_policy" {
  # Deny any request not using TLS.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.log_archive.arn, "${aws_s3_bucket.log_archive.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Deny non-KMS (e.g. SSE-S3 or unencrypted) puts.
  statement {
    sid       = "DenyIncorrectEncryptionHeader"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log_archive.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # Allow the org-level CloudTrail trail (any account in this org)
  # to check the bucket ACL and write objects.
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.log_archive.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [var.org_id]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log_archive.arn}/AWSLogs/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = [var.org_id]
    }
  }

  # VPC Flow Logs / ALB access logs delivery (delivery.logs.amazonaws.com).
  statement {
    sid       = "AWSLogDeliveryWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log_archive.arn}/AWSLogs/${var.workload_account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "AWSLogDeliveryAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.log_archive.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id
  policy = data.aws_iam_policy_document.log_archive_bucket_policy.json
}

# ---------------------------------------------------------------
# Org-level CloudTrail trail.
#
# NOTE: `is_organization_trail = true` requires this resource to
# be created with credentials in the Organizations *management*
# account, and the management account must have CloudTrail
# delegated/enabled for the org. Root main.tf applies this
# resource via a `providers = { aws = aws.management }` alias.
# ---------------------------------------------------------------

resource "aws_cloudtrail" "org_trail" {
  provider = aws.management

  name                          = var.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.log_archive.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.log_archive.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [aws_s3_bucket_policy.log_archive]
}

# ---------------------------------------------------------------
# GuardDuty (delegated administrator in the security account).
# ---------------------------------------------------------------

resource "aws_guardduty_detector" "security" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = false # no EKS in this lab
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }
}

resource "aws_guardduty_organization_admin_account" "this" {
  # Delegating admin is an Organizations-level action, run from
  # the management account.
  provider = aws.management

  admin_account_id = var.security_account_id
}

resource "aws_guardduty_member" "workload" {
  for_each = toset(var.guardduty_member_account_ids)

  account_id                 = each.value
  detector_id                = aws_guardduty_detector.security.id
  email                      = lookup(var.guardduty_member_emails, each.value, "")
  invite                     = true
  invitation_message         = "Meridian Pay security lab — GuardDuty delegated administration."
  disable_email_notification = true
}

# ---------------------------------------------------------------
# Security Hub (delegated administrator, aggregates findings incl.
# GuardDuty + Config).
# ---------------------------------------------------------------

resource "aws_securityhub_account" "security" {
  enable_default_standards = true
}

resource "aws_securityhub_organization_admin_account" "this" {
  # Delegating admin is an Organizations-level action, run from
  # the management account.
  provider = aws.management

  admin_account_id = var.security_account_id
  depends_on       = [aws_securityhub_account.security]
}

# ---------------------------------------------------------------
# AWS Config — recorder + delivery channel to the log-archive
# bucket, so configuration history is part of the audit evidence.
# ---------------------------------------------------------------

data "aws_iam_policy_document" "config_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "meridian-pay-aws-config"
  assume_role_policy = data.aws_iam_policy_document.config_assume_role.json
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_s3_write" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.log_archive.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.log_archive.arn]
  }
}

resource "aws_iam_role_policy" "config_s3_write" {
  name   = "config-s3-write"
  role   = aws_iam_role.config.id
  policy = data.aws_iam_policy_document.config_s3_write.json
}

resource "aws_config_configuration_recorder" "security" {
  name     = "meridian-pay-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "security" {
  name           = "meridian-pay-config-delivery"
  s3_bucket_name = aws_s3_bucket.log_archive.id
  s3_key_prefix  = "AWSLogs/${data.aws_caller_identity.current.account_id}/Config"

  depends_on = [aws_s3_bucket_policy.log_archive]
}

resource "aws_config_configuration_recorder_status" "security" {
  name       = aws_config_configuration_recorder.security.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.security]
}

# ---------------------------------------------------------------
# VPC Flow Logs — conditional; workload VPC doesn't exist yet.
# Enable once the workload module ships (later phase) by passing
# enable_vpc_flow_logs = true and workload_vpc_id.
# ---------------------------------------------------------------

resource "aws_flow_log" "workload_vpc" {
  count = var.enable_vpc_flow_logs ? 1 : 0

  log_destination_type = "s3"
  log_destination      = "${aws_s3_bucket.log_archive.arn}/AWSLogs/${var.workload_account_id}/vpcflowlogs"
  traffic_type         = "ALL"
  vpc_id               = var.workload_vpc_id
}

# ---------------------------------------------------------------
# ALB access logs + WAF logs — conditional; workload ALB/WAF
# don't exist yet. This bucket is already policy-wired to accept
# delivery.logs.amazonaws.com writes under the workload account
# prefix; wire the actual ALB/WAFv2 log-config resources to this
# bucket name in the ingestion/workload module when it's built.
# ---------------------------------------------------------------

# Intentionally no resources here yet — see module README note.
# Flag kept for interface stability so root main.tf doesn't need
# to change when ALB/WAF logging is turned on in a later phase.
