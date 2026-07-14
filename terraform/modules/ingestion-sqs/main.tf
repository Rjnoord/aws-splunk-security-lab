############################################################
# Phase 3 Pattern A — S3 -> SNS -> SQS ingestion for the local
# Splunk Add-on for AWS (aws_sqs_based_s3 input) to pull
# CloudTrail logs from the centralized log-archive bucket.
#
# Scope (per approved architect plan): CloudTrail sourcetype
# only. VPC Flow Logs / ALB / WAF routing is deferred — those
# log sources are still dormant (enable_vpc_flow_logs = false,
# enable_alb_waf_logs = false) in the logging module.
#
# Security-account default provider only — no management-account
# alias needed here.
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
# SNS topic — S3 publishes ObjectCreated notifications here.
# (S3 bucket notifications can fan out to SNS more flexibly than
# going straight to SQS if a second consumer is ever added.)
# ---------------------------------------------------------------

resource "aws_sns_topic" "s3_events" {
  name = "${var.name_prefix}-log-archive-s3-events"
}

data "aws_iam_policy_document" "s3_events_topic_policy" {
  statement {
    sid     = "AllowS3BucketToPublish"
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = [aws_sns_topic.s3_events.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.log_archive_bucket_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.security_account_id]
    }
  }
}

resource "aws_sns_topic_policy" "s3_events" {
  arn    = aws_sns_topic.s3_events.arn
  policy = data.aws_iam_policy_document.s3_events_topic_policy.json
}

# ---------------------------------------------------------------
# SQS — main queue + DLQ. Single queue for now (CloudTrail only);
# per-source queues can be added in a later phase if VPC Flow/WAF
# routing is turned on.
# ---------------------------------------------------------------

resource "aws_sqs_queue" "s3_events_dlq" {
  name = "${var.name_prefix}-log-archive-s3-events-dlq"
}

resource "aws_sqs_queue" "s3_events" {
  name                       = "${var.name_prefix}-log-archive-s3-events"
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.s3_events_dlq.arn
    maxReceiveCount     = var.dlq_max_receive_count
  })
}

data "aws_iam_policy_document" "s3_events_queue_policy" {
  statement {
    sid     = "AllowSnsTopicToSendMessage"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    resources = [aws_sqs_queue.s3_events.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.s3_events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "s3_events" {
  queue_url = aws_sqs_queue.s3_events.id
  policy    = data.aws_iam_policy_document.s3_events_queue_policy.json
}

resource "aws_sns_topic_subscription" "s3_events" {
  topic_arn            = aws_sns_topic.s3_events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.s3_events.arn
  raw_message_delivery = true
}

# ---------------------------------------------------------------
# S3 bucket notification.
#
# IMPORTANT: AWS only supports a single aws_s3_bucket_notification
# resource per bucket (it's not additive — a second resource here
# or in another module would silently replace/conflict with this
# one). This is the ONLY notification resource allowed on the
# log-archive bucket. If VPC Flow/WAF routing is added in a later
# phase, extend this resource's topic{} blocks rather than adding
# a new aws_s3_bucket_notification elsewhere.
# ---------------------------------------------------------------

resource "aws_s3_bucket_notification" "log_archive" {
  bucket = var.log_archive_bucket_name

  topic {
    topic_arn     = aws_sns_topic.s3_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = var.notification_filter_prefix
  }

  depends_on = [aws_sns_topic_policy.s3_events]
}

# ---------------------------------------------------------------
# IAM user for the local Splunk Add-on for AWS container.
#
# Long-lived access keys are a deliberate deviation from this
# project's SSM/OIDC-only posture elsewhere: the puller is a
# laptop Docker container, not an AWS-hosted process, so it can't
# assume a role. RJ enters these keys into the Splunk TA's setup
# page by hand (Splunk encrypts them into passwords.conf) — this
# module only provisions the user/keys/policy, it does not wire
# credentials into the container itself.
# ---------------------------------------------------------------

resource "aws_iam_user" "splunk_puller" {
  name = "${var.name_prefix}-splunk-sqs-puller"
  path = "/ingestion/"
  # No console login profile is created -> no console access.
}

resource "aws_iam_access_key" "splunk_puller" {
  user = aws_iam_user.splunk_puller.name
}

data "aws_iam_policy_document" "splunk_puller" {
  statement {
    sid    = "ConsumeS3EventsQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.s3_events.arn]
  }

  statement {
    sid       = "ListLogArchiveBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.log_archive_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.notification_filter_prefix}*"]
    }
  }

  statement {
    sid    = "ReadCloudTrailObjects"
    effect = "Allow"
    # GetObjectVersion is required (not just GetObject) because the
    # bucket has S3 Versioning enabled (a hard requirement of Object
    # Lock) — the Splunk Add-on for AWS fetches specific object
    # versions, not just the latest, and GetObject alone is
    # insufficient once a bucket is versioned.
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${var.log_archive_bucket_arn}/${var.notification_filter_prefix}*"]
  }

  statement {
    sid       = "DecryptLogArchiveObjects"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.log_archive_kms_key_arn]
  }
}

resource "aws_iam_user_policy" "splunk_puller" {
  name   = "${var.name_prefix}-splunk-sqs-puller-policy"
  user   = aws_iam_user.splunk_puller.name
  policy = data.aws_iam_policy_document.splunk_puller.json
}
