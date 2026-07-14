output "log_archive_bucket_name" {
  value = module.logging.log_archive_bucket_name
}

output "guardduty_detector_id" {
  value = module.logging.guardduty_detector_id
}

output "ssm_instance_profile_name" {
  description = "Attach this to any EC2 instance for SSM-only admin access (Phase 2 Splunk host, etc.)."
  value       = module.org_baseline.ssm_instance_profile_name
}

output "budget_sns_topic_arn" {
  value = module.org_baseline.budget_sns_topic_arn
}

# ---------------------------------------------------------------
# Phase 3 Pattern A — non-sensitive ingestion outputs only. The
# puller's secret access key is intentionally NOT surfaced as a
# root output; run
# `terraform output -raw -state=... module.ingestion_sqs.puller_secret_access_key`
# (or target it directly) when configuring the Splunk TA so it
# never appears in a plaintext `terraform output` dump of the
# whole root module.
# ---------------------------------------------------------------

output "sqs_queue_url" {
  description = "SQS queue URL for the Splunk Add-on for AWS's aws_sqs_based_s3 input."
  value       = module.ingestion_sqs.sqs_queue_url
}

output "puller_access_key_id" {
  description = "Access key ID for the Splunk SQS-puller IAM user (enter into Splunk_TA_aws account setup along with the secret key, retrieved separately)."
  value       = module.ingestion_sqs.puller_access_key_id
}
