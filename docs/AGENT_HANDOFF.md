# Agent Handoff Ledger

This file is the asynchronous coordination point for Codex, Claude Code, and
the repository owner. Keep entries concise and remove completed entries once
their changes have been accepted or committed.

## Active work

### Complete AWS TA ingestion setup

- Owner: claude
- Status: in-progress
- Scope: `splunk/Dockerfile`, `splunk/phase3-pattern-a-setup.md`, local `splunk` container
- Goal: Restore stable Splunk startup and configure the SQS-based CloudTrail input.
- Decisions/assumptions: Codex verified `splunk-ta-aws.tgz` (SHA-256 `ee25db5c8c3fc9ec0c1a41acb7e153f611cb51cac0f14b58c2de4c0a3ffbd40a`) and installed Splunk_TA_aws 8.1.2 directly into the persistent `/opt/splunk/etc/apps` volume. The existing `/opt/splunk/etc` volume masks apps copied into that path by `splunk/Dockerfile`, so the setup documentation must not claim the image layer alone installs the TA into an existing volume.
- Validation complete: Archive listed successfully; TA version is 8.1.2 in the persistent volume. AWS ingestion Terraform resources exist in root state. Codex recreated the disposable container with the correct existing credential and both original named volumes; the container is now healthy and the TA version file is present.
- Validation remaining: Restore a healthy container, confirm `Splunk_TA_aws` loads, configure the AWS account and SQS input, then prove real data with `index=aws_cloudtrail | stats count by eventName`.
- Next action: Configure the TA AWS account and SQS-based S3 input without persisting plaintext credentials in the repository, then run the real-data SPL validation. Update `splunk/phase3-pattern-a-setup.md` to correct the existing-volume/image-layer behavior.

### Apply and validate Splunk puller IAM fix

- Owner: claude
- Status: ready
- Scope: `terraform/modules/ingestion-sqs/main.tf`, deployed IAM inline policy, local Splunk TA input
- Goal: Allow the configured SQS-based S3 input to download versioned CloudTrail objects.
- Decisions/assumptions: The input is saved and running. Splunk successfully receives SQS messages but every S3 download fails because the deployed IAM policy lacks `s3:GetObjectVersion`. The working tree already adds this action beside `s3:GetObject`; preserve that least-privilege resource scope. `sqs:ListQueues` errors occurred only while the UI attempted queue discovery; the saved input uses the explicit queue URL and does not require broad `ListQueues` permission.
- Validation complete: Effective Splunk input verified with `btool`; TA log proves `AccessDenied` specifically for `s3:GetObjectVersion` on versioned CloudTrail and digest objects. Terraform formatting previously passed.
- Validation remaining: Review the pending Terraform diff, run a targeted/full plan, apply the IAM policy update with RJ's approval, then confirm TA errors stop and `index=aws_cloudtrail | stats count by eventName` returns real events.
- Next action: Apply the existing IAM policy change; do not add `sqs:ListQueues` unless queue dropdown discovery is explicitly required.

### Cost-optimization teardown of live AWS resources

- Owner: claude
- Status: done
- Scope: live AWS security-account infra only (no Terraform code changes)
- Goal: Reduce ongoing AWS cost by tearing down actively-billing lab resources while preserving audit log data.
- Decisions/assumptions: Kept `module.logging.aws_s3_bucket.log_archive` and its full protection stack (KMS key, versioning, encryption, object lock, public-access block, bucket policy) intact per AGENTS.md's rule against weakening encryption/retention/audit logging. Destroyed via `terraform destroy -target=...`: `module.ingestion_sqs` (SQS/SNS pipeline), `module.logging.aws_securityhub_account.security`, `module.logging.aws_cloudtrail.org_trail`, GuardDuty detector/member/org-admin. Two org SCPs (`deny_disable_guardduty`, `deny_disable_cloudtrail`) blocked GuardDuty/CloudTrail deletion with an explicit deny — RJ approved temporarily detaching those SCP attachments (`aws_organizations_policy_attachment` for `r-ie3q`) to complete teardown; the SCP policy documents themselves still exist in state, only the attachments were destroyed.
- Validation complete: `terraform plan -destroy` reviewed before every apply; final `terraform plan` shows 18 resources would be recreated (matches everything torn down) and 0 drift/unexpected changes.
- Validation remaining: None for teardown. If the lab is rebuilt, `terraform apply` recreates the 18 destroyed resources, including reattaching the two SCPs — confirm that's still desired before reapplying.
- Next action: None open. Screenshots for the repo were deferred — RJ is capturing those manually and will hand them off for commit.

## Entry template

Copy this block under **Active work**:

```markdown
### Short task name

- Owner: codex | claude | human
- Status: ready | in-progress | blocked | done
- Scope: `path/to/file`, `path/to/other-file`
- Goal: One sentence describing the expected outcome.
- Decisions/assumptions: What the next agent must preserve or verify.
- Validation complete: Commands/checks already run and their results.
- Validation remaining: Commands/checks the next agent should run.
- Next action: The concrete next step and intended recipient.
```

## Coordination notes

- The ledger coordinates work through the shared filesystem; it is not a live
  chat channel between agent runtimes.
- One owner edits a scoped file at a time. A reviewer should avoid edits until
  the owner marks the entry `ready` or explicitly requests implementation.
- Check `git status --short` and the relevant diff before starting or resuming.
- Never use this file for secrets, credentials, account IDs, or HEC tokens.
