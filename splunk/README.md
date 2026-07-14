# Splunk artifacts

SPL searches, dashboards, props/transforms. Populated in Phase 4 from docs/DETECTIONS.md.

## Phase 2 — local Docker Splunk (current)

Phase 2 is running against RJ's existing local Splunk container (`docker` container name `splunk`, image `splunk/splunk:latest`) rather than a hardened EC2 build. The EC2/ALB/SSM/Secrets Manager version described in `docs/PLAN.md` Phase 2 is deferred until the project moves toward Phase 5 (attack simulation), when the real cloud architecture is needed.

Ports (already mapped to localhost):
- `8000` — Splunk Web
- `8088` — HTTP Event Collector (HEC)
- `8089` — management/REST API

Config applied via `etc/system/local/indexes.conf` and `etc/system/local/inputs.conf` inside the container (edited directly, not through Splunk Web), then `docker restart splunk` to apply:

**Indexes** (retention per `docs/ARCHITECTURE.md` §3):
| Index | Retention |
|---|---|
| `aws_cloudtrail` | 400d |
| `aws_vpcflow` | 30d |
| `aws_security` | 180d |
| `aws_waf` | 30d |

**HEC input:** stanza `[http://aws_lab_hec]`, TLS enabled (`enableSSL = 1`), scoped to the 4 indexes above, default index `aws_security`. Token was generated locally and is not committed anywhere in this repo — it lives only in the container's `inputs.conf`. If you need it again, read it from inside the container (`docker exec splunk cat /opt/splunk/etc/system/local/inputs.conf`) rather than regenerating, or regenerate and update any downstream consumers.

**Verified:** `curl` to `https://localhost:8088/services/collector/event` with the token returned `{"text":"Success","code":0}` — satisfies Phase 2's DoD test-event requirement. Confirm in Splunk Web (`index=aws_security | head 1`) to fully close out the DoD.

## Phase 3 — Pattern A (S3 → SNS → SQS)

Terraform for the AWS side lives in `terraform/modules/ingestion-sqs/`. Splunk-side install/config steps (Dockerfile extending this same container with the Splunk Add-on for AWS, `aws_sqs_based_s3` input, IAM credential entry) are documented in `splunk/phase3-pattern-a-setup.md`. CloudTrail sourcetype only for now — VPC Flow/WAF are deferred until those log sources are enabled. Pattern B (EventBridge → Firehose → HEC) is deferred; see `docs/PLAN.md` Phase 3 note.
