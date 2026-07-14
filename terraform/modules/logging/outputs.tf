output "log_archive_bucket_name" {
  description = "S3 bucket name for the centralized log archive (CloudTrail, VPC FL, ALB/WAF, Config)."
  value       = aws_s3_bucket.log_archive.id
}

output "log_archive_bucket_arn" {
  value = aws_s3_bucket.log_archive.arn
}

output "log_archive_kms_key_arn" {
  description = "CMK ARN used to encrypt all log-archive objects. Needed by downstream ingestion (SQS/Firehose) permissions in later phases."
  value       = aws_kms_key.log_archive.arn
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.org_trail.arn
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.security.id
}

output "config_recorder_name" {
  value = var.enable_aws_config ? aws_config_configuration_recorder.security[0].name : null
}
