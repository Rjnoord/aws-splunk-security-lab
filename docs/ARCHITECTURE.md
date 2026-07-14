# Architecture — Meridian Pay Security Lab

## 1. Design goals & constraints

**Goals**
1. Cloud-native, centralized security telemetry into Splunk acting as the SIEM.
2. Cover the majority of AWS Security Specialty logging/detection surface with real data.
3. Exercise Splunk Core skills end-to-end: ingest → index → search (SPL) → field extraction → reports → dashboards → alerts.
4. Demonstrate automated detection **and** response, not just collection.
5. Produce audit evidence (retention, encryption, access control) a PCI/SOC 2 assessor would accept.

**Constraints (deliberate, because they mirror real business trade-offs)**
- Single AWS Organization, **two accounts**: `security` (log archive + Splunk + GuardDuty admin) and `workload` (the payments app + attack surface). This teaches cross-account log delivery — a core SCS theme — without the cost of a full 5-account landing zone.
- Splunk runs as **Splunk Enterprise single instance on EC2** (indexer + search head + HF combined) to keep cost low. The design notes where this would split into a distributed deployment (indexer cluster + dedicated SH) in production, because the exam and interviews will ask.
- Everything is Terraform-managed and destroyable in one command.

## 2. Account & network topology

```
AWS Organization (management account – billing/SCP only)
│
├── security account
│   ├── S3 log-archive bucket (CloudTrail org trail, VPC FL, ALB/WAF) — KMS-encrypted, Object Lock
│   ├── GuardDuty (delegated administrator)
│   ├── Security Hub (delegated administrator, aggregates findings)
│   ├── Splunk Enterprise EC2 (private subnet, ALB in front for web, SSM-only admin)
│   └── SQS + SNS ingestion queues for the Splunk Add-on for AWS
│
└── workload account   (the thing being attacked / monitored)
    ├── VPC: 2 AZ, public ALB + private app subnets + NAT
    ├── Payments API (ECS Fargate or single EC2 "app" host)
    ├── RDS PostgreSQL (cardholder data store – KMS encrypted)
    ├── An intentionally reachable "canary" IAM user + S3 bucket for attack sims
    └── Local log sources: VPC Flow Logs, WAF, ALB access logs, GuardDuty agent
```

**Network security decisions**
- Splunk EC2 lives in a **private subnet**; no public IP. Admin is via **SSM Session Manager only** (no bastion, no port 22 open) — this is a direct SCS Domain 3 talking point.
- Splunk Web (8000) and HEC (8088) are reachable only through an internal ALB + security-group allowlist; HEC token auth + TLS required.
- Security groups are least-privilege and referenced by SG ID, never `0.0.0.0/0` except the public ALB on 443.

## 3. Data sources → ingestion pipelines

Two ingestion patterns on purpose, because both appear on the SCS exam and in real Splunk deployments:

### Pattern A — Pull from S3 via SQS (bulk, high-volume logs)
```
CloudTrail (org trail) ─┐
VPC Flow Logs           ├─► S3 log-archive ─► S3 Event Notification ─► SNS ─► SQS ─► Splunk Add-on for AWS (SQS-based S3 input) ─► index=aws_cloudtrail / aws_vpcflow
ALB / WAF access logs  ─┘
```
- Decoupled, replayable, survives Splunk downtime (messages wait in SQS). This is the recommended modern pattern (over the deprecated "Generic S3" polling input) — know *why*: no missed/duplicate objects, scales, no full-bucket re-scans.

### Pattern B — Push near-real-time via HEC (findings & events)
```
GuardDuty findings ─┐
Security Hub        ├─► EventBridge rule ─► Kinesis Data Firehose ─► Splunk HEC (event endpoint, token auth, TLS) ─► index=aws_security
AWS Config changes ─┘                                         └─► S3 backsplash bucket (Firehose delivery failures)
```
- Low latency for detections; Firehose gives buffering, retry, and a dead-letter S3 path. Know the failure-handling story cold — it's a favorite exam wrinkle.

### Index design (Splunk Core skill)
| Index | Sources | Retention | Why |
|---|---|---|---|
| `aws_cloudtrail` | CloudTrail | 90d hot/warm, 400d frozen-to-S3 | High volume, primary detection source |
| `aws_vpcflow` | VPC Flow Logs | 30d | Network detections, noisy |
| `aws_security` | GuardDuty, Security Hub, Config | 180d | Findings, lower volume, longer retention for audit |
| `aws_waf` | WAF, ALB | 30d | Web attack detection |

Separate indexes = separate retention + RBAC + faster searches (Splunk scopes by index). This is a Power User–level design decision, not an accident.

## 4. Detection & response layer

- **Correlation searches** run as scheduled Splunk saved searches (Enterprise tier; note that in prod this is Enterprise Security's job, but Core-level scheduled alerts prove the same concept). See `DETECTIONS.md`.
- **Automated response**: high-severity GuardDuty finding → EventBridge → Lambda that (a) tags/quarantines the offending resource via a restrictive SG, (b) disables the compromised IAM access key, (c) posts an event back into Splunk via HEC for the audit trail. This closes the detect→respond loop and is a strong portfolio/interview artifact.

## 5. Data protection & IAM (SCS Domains 4 & 5)

- All S3 buckets: SSE-KMS with a customer-managed key, bucket policy denies non-TLS and non-KMS puts, Block Public Access on, **Object Lock** on the log archive for tamper-evidence (PCI/SOC 2 requirement — logs auditors can trust).
- Cross-account log delivery uses a bucket policy + KMS key policy granting the org trail and Firehose principals least-privilege — a classic SCS scenario.
- IAM: permission boundaries on the automation Lambda, an `AccessAnalyzer` enabled to catch unintended external access, and one deliberately over-permissioned "legacy" role for the detection lab to catch.
- Secrets (Splunk HEC token, RDS creds) live in **Secrets Manager**, never in Terraform state in plaintext.

## 6. What would change in production (say this in interviews)
- Splunk: split into an indexer cluster (3+ peers, replication factor) + dedicated search head(s) + heavy forwarders; use SmartStore for S3-backed storage.
- Move to a full multi-account landing zone (Control Tower) with a dedicated log-archive account.
- Enterprise Security or a risk-based alerting framework instead of hand-rolled correlation searches.
- Cross-region failover for the SIEM; the lab is single-region (`us-east-1`) for cost.

## 7. Region & cost posture
- Single region `us-east-1`. Splunk on `t3.large` (min viable for Enterprise). GuardDuty, Firehose, and data egress are the recurring costs — tracked per phase in `PLAN.md`. Full teardown between sessions is expected.
