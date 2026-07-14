# Phase 3 — Pattern A setup (S3 → SNS → SQS → Splunk Add-on for AWS)

Scope: CloudTrail sourcetype only for now. VPC Flow Logs and WAF routing
are deferred until those log sources are actually enabled in
`terraform/modules/logging` (`enable_vpc_flow_logs` / `enable_alb_waf_logs`
are still `false`) — the single SQS queue/notification built in
`terraform/modules/ingestion-sqs` can be extended for those later without
re-architecting.

Terraform in `terraform/modules/ingestion-sqs/` provisions the AWS side:
SNS topic, SQS queue + DLQ, S3 bucket notification (`AWSLogs/` prefix),
and an IAM user (`meridian-pay-splunk-sqs-puller`) with least-privilege
access scoped to that one queue/bucket-prefix/KMS key. **None of this has
been applied to real AWS yet** — this doc describes the steps to run
*after* `terraform apply` for this module.

## 1. Build the TA into the local Splunk image

Phase 2's container (`splunk`, image `splunk/splunk:latest`, run via
`docker run` with named volumes for `etc`/`var`) doesn't have the Splunk
Add-on for AWS installed. Rather than dropping files into a running
container by hand (which named volumes would then hide on rebuild),
extend the image with a small Dockerfile so the TA survives
recreate/rebuild:

```dockerfile
# splunk/Dockerfile
FROM splunk/splunk:latest

# Splunkbase app 1876 — Splunk Add-on for Amazon Web Services.
# Download the .tgz from Splunkbase manually (requires a Splunk.com
# login) and place it next to this Dockerfile as splunk-ta-aws.tgz —
# do not commit the .tgz itself to the repo.
COPY splunk-ta-aws.tgz /tmp/splunk-ta-aws.tgz
RUN mkdir -p $SPLUNK_HOME/etc/apps \
 && tar -xzf /tmp/splunk-ta-aws.tgz -C $SPLUNK_HOME/etc/apps \
 && rm /tmp/splunk-ta-aws.tgz
```

Build and run it the same way Phase 2's container was run, but pointing
at this image and keeping the same named volumes (`etc`/`var`) so the
Phase 2 indexes/inputs config carries forward:

```bash
docker build -t meridian-pay-splunk:phase3 -f splunk/Dockerfile splunk/
docker stop splunk && docker rm splunk
docker run -d --name splunk \
  -p 8000:8000 -p 8088:8088 -p 8089:8089 \
  -v splunk-etc:/opt/splunk/etc \
  -v splunk-var:/opt/splunk/var \
  -e SPLUNK_START_ARGS=--accept-license \
  -e SPLUNK_PASSWORD=<existing local admin password> \
  meridian-pay-splunk:phase3
```

Confirm the app loaded: Splunk Web (`https://localhost:8000`) → Apps →
should list **Splunk Add-on for AWS**.

## 2. Configure the AWS input

In Splunk Web: **Splunk_TA_aws → Configuration → Inputs → Create New
Input → SQS-Based S3**.

| Field | Value |
|---|---|
| Name | `meridian-pay-cloudtrail-sqs` |
| AWS Account | (created in step 3) |
| Region | `us-east-1` |
| SQS Queue URL | output of `module.ingestion_sqs.sqs_queue_url` (also surfaced as root output `sqs_queue_url` — get it with `terraform output sqs_queue_url` after apply) |
| Source type | `aws:cloudtrail` (should auto-assign; verify it did) |
| Index | `aws_cloudtrail` (already created in Phase 2) |

## 3. Enter IAM credentials

**Splunk_TA_aws → Configuration → Account → Add**. Use:
- Access Key ID: `terraform output puller_access_key_id` (also a root
  output).
- Secret Access Key: `terraform output -raw module.ingestion_sqs.puller_secret_access_key`
  (marked `sensitive` — not surfaced as a root output on purpose; pull it
  from the module output directly, once, and paste it straight into
  Splunk Web. Don't paste it into a shell history file, a `.env`, or
  anywhere else in this repo.)

Splunk encrypts these into `passwords.conf` under the app's local
directory — this is the *only* place the long-lived keys should end up
living outside AWS IAM itself. Terraform does not and will not write
these into any file, env var, or container injection mechanism; entering
them is a manual step done once via Splunk Web.

## 4. Validate (DoD)

After the input has had a few minutes to pull backlog:

```
index=aws_cloudtrail | stats count by eventName
```

should return real event names (`ConsoleLogin`, `AssumeRole`, etc.) from
live CloudTrail activity in the org. If it returns nothing after ~5
minutes, check:
- The SQS queue's `ApproximateNumberOfMessagesVisible` (CloudWatch) — if
  it's climbing and not draining, the TA account/permissions are wrong.
- The DLQ — if messages are landing there, the puller's IAM policy or
  the SNS→SQS subscription (`raw_message_delivery = true`) is
  misconfigured.
- CloudTrail is actually delivering to the bucket under the `AWSLogs/`
  prefix (the bucket notification's `filter_prefix`).
