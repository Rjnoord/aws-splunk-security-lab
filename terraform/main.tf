############################################################
# Root module — wires org-baseline (Phase 0) and logging
# (Phase 1) together. Later phases (splunk-ec2, ingestion,
# response-lambda) will be added as additional module blocks
# here without restructuring what already exists.
############################################################

module "org_baseline" {
  source = "./modules/org-baseline"

  providers = {
    aws = aws.management
  }

  region                = var.region
  org_id                = var.org_id
  management_account_id = var.management_account_id
  security_account_id   = var.security_account_id
  workload_account_id   = var.workload_account_id
  budget_limit_usd      = var.budget_limit_usd
  budget_alert_email    = var.budget_alert_email
}

module "logging" {
  source = "./modules/logging"

  providers = {
    aws            = aws
    aws.management = aws.management
  }

  # Bucket, KMS, GuardDuty/Security Hub/Config detector all live in
  # the security account -> default provider. A few org-level
  # actions (org CloudTrail trail, GuardDuty/Security Hub delegated
  # admin) require the management-account provider internally.
  region                       = var.region
  security_account_id          = var.security_account_id
  workload_account_id          = var.workload_account_id
  org_id                       = var.org_id
  log_archive_bucket_name      = var.log_archive_bucket_name
  enable_vpc_flow_logs         = var.enable_vpc_flow_logs
  workload_vpc_id              = var.workload_vpc_id
  guardduty_member_account_ids = var.guardduty_member_account_ids
  guardduty_member_emails      = var.guardduty_member_emails
}

module "ingestion_sqs" {
  source = "./modules/ingestion-sqs"

  providers = {
    aws = aws
  }

  # Phase 3 Pattern A: S3 -> SNS -> SQS so the local Splunk
  # container can pull CloudTrail logs via the Splunk Add-on for
  # AWS's aws_sqs_based_s3 input. Security-account default
  # provider only, fed from module.logging's outputs.
  region                  = var.region
  security_account_id     = var.security_account_id
  log_archive_bucket_name = module.logging.log_archive_bucket_name
  log_archive_bucket_arn  = module.logging.log_archive_bucket_arn
  log_archive_kms_key_arn = module.logging.log_archive_kms_key_arn
}
