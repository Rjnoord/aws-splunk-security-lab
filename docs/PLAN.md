# Build Plan — Phased, with exit criteria and cost checkpoints

Work these in order. Each phase has a **Definition of Done (DoD)** and a **cost checkpoint**. Do not advance until the DoD is met — later detections depend on earlier data being live. Estimated costs assume `us-east-1`, teardown between sessions.

---

## Phase 0 — Foundations (½ day)
**Goal:** accounts, IaC, and guardrails before any data flows.

- [ ] AWS Organization with `security` + `workload` accounts (or two existing accounts).
- [ ] Terraform backend: S3 state bucket + DynamoDB lock table, KMS-encrypted.
- [ ] SCP baseline: deny leaving `us-east-1`, deny disabling CloudTrail/GuardDuty.
- [ ] Budget alarm at $50/mo via AWS Budgets → SNS → your email.
- [ ] SSM Session Manager configured (IAM instance profile, no SSH keys).

**DoD:** `terraform apply` from zero creates both accounts' baselines; you can open an SSM session to a test EC2 host with no open port 22.
**Cost checkpoint:** ~$0 idle (S3/DynamoDB state negligible).
**Exam tie-in:** SCS Domain 3 (SSM vs bastion), Domain 4 (SCPs, org structure).

---

## Phase 1 — Centralized logging (1 day)
**Goal:** all AWS log sources landing in an encrypted, tamper-evident archive.

- [ ] Org-level CloudTrail → S3 log-archive bucket in `security` account.
- [ ] VPC Flow Logs (workload VPC) → S3.
- [ ] ALB access logs + WAF logs → S3.
- [ ] Enable GuardDuty (delegated admin in `security`), Security Hub, AWS Config.
- [ ] Bucket hardening: SSE-KMS (CMK), Block Public Access, deny-non-TLS policy, **Object Lock** on log archive.

**DoD:** new API activity in `workload` appears as objects in the `security` bucket within minutes; bucket rejects a plaintext/non-TLS PUT; GuardDuty shows the sample findings.
**Cost checkpoint:** GuardDuty ~$1–4/day depending on CloudTrail volume; S3 pennies. **This is the meter that runs — track it.**
**Exam tie-in:** SCS Domain 2 (logging architecture), Domain 5 (S3 encryption, Object Lock, bucket policies).

---

## Phase 2 — Stand up Splunk (½ day)
**Goal:** Splunk Enterprise reachable, hardened, ready to ingest.

- [ ] Terraform: EC2 `t3.large` in private subnet, Splunk Enterprise installed via user-data/Ansible.
- [ ] Internal ALB → Splunk Web (8000) and HEC (8088), TLS, SG allowlist only.
- [ ] Admin access via SSM only. HEC token stored in Secrets Manager.
- [ ] Create indexes: `aws_cloudtrail`, `aws_vpcflow`, `aws_security`, `aws_waf` with the retention from ARCHITECTURE.md §3.

**DoD:** you reach Splunk Web through the ALB; a manual `curl` to HEC with the token indexes a test event into `aws_security`.
**Cost checkpoint:** `t3.large` ~$0.083/hr (~$2/day if left on). **Stop the instance when not studying.**
**Exam tie-in:** Splunk Core (indexes, HEC, inputs); SCS Domain 3 (private subnet, SSM, SG design).

---

## Phase 3 — Ingestion pipelines (1 day)
**Goal:** both ingestion patterns live and validated.

- [x] **Pattern A:** S3 → SNS → SQS; install Splunk Add-on for AWS; configure SQS-based S3 input for CloudTrail, VPC Flow, WAF. Confirm sourcetypes auto-assign.
  - Built as `terraform/modules/ingestion-sqs` (CloudTrail sourcetype only — VPC Flow/WAF are still dormant log sources per Phase 1, so only one SQS queue was built; extend the same module's `aws_s3_bucket_notification` topic block when those are enabled rather than adding a second notification resource). Splunk-side TA install/config steps documented in `splunk/phase3-pattern-a-setup.md`. Not yet applied to real AWS.
- [ ] **Pattern B:** EventBridge (GuardDuty/Security Hub/Config) → Kinesis Firehose → Splunk HEC; configure Firehose S3 backsplash for failures.
  - **Deferred:** the local Splunk container (Phase 2) can't receive an inbound Firehose HTTP endpoint delivery from a laptop behind NAT — Firehose needs a reachable HTTPS endpoint. Pattern B needs either a public HEC endpoint (ngrok/tunnel) or to wait until Phase 5's real EC2-hosted Splunk exists. Bullets left unchecked and in place; do not build a workaround for the local-container limitation without RJ's sign-off.
- [ ] Validate: `index=aws_cloudtrail | stats count by eventName` returns real data; GuardDuty findings appear in `aws_security` within ~2 min.

**DoD:** all four indexes populate automatically from live AWS activity; killing Splunk for 10 min and restarting shows SQS backlog drained (no data loss) — proves the decoupled design.
**Cost checkpoint:** Firehose ~$0.029/GB + SQS/SNS pennies. Low.
**Exam tie-in:** SCS Domain 2 (log delivery patterns, Firehose failure handling); Splunk Core (add-ons, sourcetypes, field extraction).

---

## Phase 4 — Detections & dashboards (2 days) — the centerpiece
**Goal:** turn raw logs into detections, alerts, and an operational dashboard. Full SPL detail in `DETECTIONS.md`.

- [x] Build the 8 core detection searches (root usage, console login without MFA, IAM policy change, CloudTrail tampering, GuardDuty high-sev, unusual region, S3 public-access change, RDS/data exfil signal).
- [x] Convert each to a scheduled alert with throttling; route high-sev to SNS/email.
  - Built as the Splunk app `splunk/apps/aws_security_lab/` (`savedsearches.conf`). Email routing: D1 (root usage), D4 (CloudTrail tampering), D5 (GuardDuty high-sev), D7 (public S3) get `action.email = 1` with a placeholder `$email$` token; D2/D3/D6/D8 are scheduled/dashboard-visible only. SMTP + the real recipient address are a manual, uncommitted step for RJ — see `splunk/phase4-detections-setup.md`. Not yet deployed to the running container.
  - D5 (index=aws_security, GuardDuty) and D8 (index=aws_vpcflow) are correctly configured but will return no real data until Phase 3 Pattern B and VPC Flow Log delivery are enabled (both still unchecked above).
- [x] Build a **SOC Overview dashboard**: findings by severity, top eventNames, failed logins by source IP (geo), API calls by region, detection-hit timeline.
  - `splunk/apps/aws_security_lab/default/data/ui/views/soc_overview.xml`. Detection-hit timeline reads from a new `summary_detections` summary index (`indexes.conf`) that all 8 alerts write to via `summary_index` alert action.
- [x] Build one **investigation dashboard** with drilldown (click a user → their CloudTrail timeline).
  - `splunk/apps/aws_security_lab/default/data/ui/views/investigation.xml`.

**DoD:** you can trigger each detection with a controlled action (Phase 5), see the alert fire, and pivot in the dashboard. Config is built and app-packaged; deployment into the running container and full DoD validation (real alert fires, dashboard pivot) are documented as manual next steps in `splunk/phase4-detections-setup.md` — actual triggering of detections is Phase 5 scope.
**Cost checkpoint:** compute-bound on the one instance; ~$0 incremental.
**Exam tie-in:** Splunk Core/Power User (SPL, `stats`/`eval`/`stats` correlation, transforming commands, dashboards, scheduled alerts, drilldowns); SCS Domain 1 (detection engineering).

---

## Phase 5 — Attack simulation & validation (1 day)
**Goal:** prove the detections work by generating real malicious-looking activity.

- [ ] Use the "canary" IAM user + Stratus Red Team (or manual AWS CLI) to simulate: credential exfil, disabling CloudTrail, making an S3 bucket public, unusual-region API calls, console login without MFA.
- [ ] Confirm each fires its detection and appears on the dashboard. Screenshot for the portfolio.
- [ ] Write a short detection-efficacy table: technique → ATT&CK ID → detected? → time-to-alert.

**DoD:** every Phase 4 detection has at least one validated true-positive with a timestamped alert.
**Exam tie-in:** SCS Domain 1 (threat detection & IR); interview gold.

---

## Phase 6 — Automated response (1 day)
**Goal:** close the loop from detect to contain.

- [ ] EventBridge rule: high-sev GuardDuty finding → Lambda.
- [ ] Lambda actions: disable offending IAM access key, apply quarantine SG, write an audit event back to Splunk via HEC.
- [ ] Lambda has a permission boundary; actions are logged and reversible.
- [ ] Add a "Response Actions" panel to the SOC dashboard sourced from the audit events.

**DoD:** triggering a simulated compromise auto-disables the key within ~1 min and the action is visible in Splunk.
**Exam tie-in:** SCS Domain 1 (automated incident response) — one of the highest-weighted objectives.

---

## Phase 7 — Audit evidence & write-up (½ day)
**Goal:** package it as a portfolio + audit artifact.

- [ ] Runbooks in `runbooks/` for each detection (what it means, how to investigate, how to respond).
- [ ] Evidence pack: encryption config, retention, RBAC, Object Lock proof, sample alerts — mapped to PCI-DSS / SOC 2 controls.
- [ ] LinkedIn post + architecture diagram (Tier 2 brand win — ties to your goals).
- [ ] `EXAM-MAPPING.md` filled in as a traceability matrix.

**DoD:** a stranger can read the repo and understand the design, the detections, and the business value without you explaining it.

---

## Teardown (every session)
`terraform destroy` the workload compute + stop/terminate Splunk EC2. Leave the log-archive bucket (cheap, keeps evidence) unless you want a full reset. Use the **janitor** agent for this. Recurring meter killers to kill first: **Splunk EC2, GuardDuty, Firehose**.

## Total time estimate
~8 working days of focused effort. Realistically 3–4 weeks part-time alongside CCNA study. Sequence it so Phase 4 (detections) lands before your AWS Security exam date — that's the domain-1 material that's hardest to learn from a book.
