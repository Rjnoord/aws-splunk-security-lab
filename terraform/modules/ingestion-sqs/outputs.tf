output "sqs_queue_url" {
  description = "URL of the main S3-events SQS queue. Used as the `SQS Queue URL` field of the Splunk aws_sqs_based_s3 input."
  value       = aws_sqs_queue.s3_events.id
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.s3_events.arn
}

output "dlq_arn" {
  value = aws_sqs_queue.s3_events_dlq.arn
}

output "sns_topic_arn" {
  value = aws_sns_topic.s3_events.arn
}

output "puller_iam_user_arn" {
  value = aws_iam_user.splunk_puller.arn
}

output "puller_access_key_id" {
  description = "Access key ID for the Splunk SQS-puller IAM user. Enter into the Splunk_TA_aws account setup page — do not store in env vars/files checked into the repo."
  value       = aws_iam_access_key.splunk_puller.id
}

output "puller_secret_access_key" {
  description = "Secret access key for the Splunk SQS-puller IAM user. Sensitive — never print/log this; enter directly into Splunk Web's TA setup page."
  value       = aws_iam_access_key.splunk_puller.secret
  sensitive   = true
}
