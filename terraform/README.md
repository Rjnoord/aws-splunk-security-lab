# Terraform — Meridian Pay Security Lab

Modules (per `../docs/PLAN.md`): `org-baseline`, `logging`, `splunk-ec2`,
`ingestion`, `response-lambda`.

**Currently built:** `org-baseline` (Phase 0) and `logging` (Phase 1).
`splunk-ec2`, `ingestion`, and `response-lambda` are intentionally not
started yet — they belong to later phases per `PLAN.md` and depend on
infrastructure (workload VPC, Splunk host) this pass doesn't build.

## Layout

```
terraform/
├── bootstrap/          # one-time, human-run, local-state only (see below)
├── modules/
│   ├── org-baseline/    # SCPs, budget alarm -> SNS -> email, SSM-only IAM
│   └── logging/         # log-archive S3 bucket, org CloudTrail, GuardDuty,
│                         # Security Hub, AWS Config, (conditional) VPC FL
├── main.tf              # root module wiring org-baseline + logging
├── provider.tf           # backend "s3" block + aws / aws.management providers
├── variables.tf
├── outputs.tf
└── terraform.tfvars.example
```

## Two-step bootstrap (human-run, before CI can do anything)

Terraform can't create the backend it's about to store state in, and
GitHub Actions can't create the IAM role it needs to authenticate as.
Both are solved the same way: a small local-state config applied once,
by hand, with real AWS credentials on your machine.

### Step 1 — state backend + GitHub OIDC role

```
cd terraform/bootstrap
terraform init
terraform apply \
  -var="state_bucket_name=meridian-pay-tfstate-<your-account-id>" \
  -var="github_org=<your-github-username-or-org>"
```

This creates:
- KMS-encrypted, versioned S3 bucket for Terraform state (Object Lock is
  *not* used here — state needs to be mutable; the log-archive bucket in
  the `logging` module is the one that's Object Lock–protected).
- DynamoDB table for state locking.
- A GitHub OIDC provider + **two** IAM roles, split by privilege and by
  trust condition:
  - `meridian-pay-github-actions-plan` — trusted only for
    `pull_request`-triggered workflow runs on this repo (`sub =
    repo:ORG/REPO:pull_request`). Carries `ReadOnlyAccess` only — no
    write, no IAM, no Organizations access. This is the role used by
    the PR/plan job; GitHub exposes its ARN (a repo *variable*, not a
    secret) even to workflow runs triggered by forked-repo PRs, so it
    must never be able to mutate anything.
  - `meridian-pay-github-actions-apply` — trusted only for the `sub`
    claim GitHub emits when a job runs under the `production`
    GitHub Environment (`sub =
    repo:ORG/REPO:environment:production`), which requires human
    reviewer approval. Carries `PowerUserAccess` plus a narrow,
    explicit IAM (scoped to `role/meridian-pay-*`, not `*`) and
    Organizations (explicit SCP/delegated-admin action list, not
    `organizations:*`) policy — just enough to apply org-baseline and
    logging, with no privilege-escalation path via `iam:PassRole` +
    `iam:AttachRolePolicy` on `*`.

Copy the outputs:
- `state_bucket_name` / `lock_table_name` -> paste into `terraform/provider.tf`
  `backend "s3"` block (replace the `REPLACE_WITH_BOOTSTRAP_OUTPUT_*`
  placeholders).
- `github_actions_plan_role_arn` -> set as the `AWS_OIDC_PLAN_ROLE_ARN`
  **repository variable** (not secret — it's not sensitive) in GitHub
  repo settings.
- `github_actions_apply_role_arn` -> set as the `AWS_OIDC_APPLY_ROLE_ARN`
  **repository variable** in GitHub repo settings.

### Step 2 — GitHub repo configuration

- Repo variable `AWS_OIDC_PLAN_ROLE_ARN` = the plan role ARN from Step 1.
- Repo variable `AWS_OIDC_APPLY_ROLE_ARN` = the apply role ARN from Step 1.
- Repo secret `BUDGET_ALERT_EMAIL` = your real email (passed to Terraform
  as `TF_VAR_budget_alert_email`, never committed to a `.tfvars` file).
- A GitHub **Environment** named `production` with required reviewers
  configured (Settings → Environments → New environment). The `apply`
  job in `.github/workflows/terraform.yml` is gated behind this
  environment — pushing to `main` will *not* auto-apply without a human
  approval click, AND the apply role's IAM trust policy independently
  rejects any OIDC token whose `sub` claim isn't
  `repo:ORG/REPO:environment:production`, so the gate is enforced by
  AWS, not just by the workflow file. This is deliberate: this stack
  touches SCPs, CloudTrail, and GuardDuty across the org, plus real AWS
  spend.

After both steps, running `terraform init` in `terraform/` (root) picks
up the real S3/DynamoDB backend, and CI can plan/apply.

## Running modules locally

```
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in real values, gitignored
terraform init
terraform plan
terraform apply   # do not run without reviewing the plan; this is a live AWS org
```

Two provider identities are in play (`provider.tf`):
- Default `aws` provider — the `security` account (log archive, GuardDuty
  detector, Security Hub, Config recorder all live here).
- `aws.management` alias — the AWS Organizations management account.
  Required for SCP attachment (`org-baseline`) and for a few resources
  inside `logging` that can only be created from the management account:
  the org-level CloudTrail trail (`is_organization_trail = true`) and the
  GuardDuty/Security Hub delegated-administrator registrations. Set
  `management_role_arn` if your CI/local principal needs to assume a
  role in the management account; leave it `null` to apply directly as a
  management-account identity.

## CI/CD

`.github/workflows/terraform.yml`:
- **On pull request:** `terraform fmt -check`, `terraform validate`,
  `tflint`, a Checkov scan (`soft_fail: true` for now — surfaces findings
  without blocking merges while the modules are still young), and
  `terraform plan` (read-only AWS access via OIDC; only runs once the
  `AWS_OIDC_ROLE_ARN` repo variable exists, so a fresh clone before
  bootstrap still passes the lint/validate stages). Nothing is ever
  auto-applied from a PR.
- **On push to `main`:** `terraform apply`, gated behind the `production`
  GitHub Environment's required-reviewer approval. Uses the same OIDC
  role, no static AWS keys in GitHub secrets at any point.

**Checkov vs tfsec:** Checkov was chosen over tfsec for the scanning
step. tfsec's engine has been folded into Aqua's Trivy/Checkov tooling
line, and Checkov ships broader out-of-the-box policy coverage for the
kind of controls this lab is trying to demonstrate (S3 encryption/
Block Public Access, IAM least-privilege, CloudTrail/Config coverage) —
useful both as a CI gate and as portfolio evidence of a real security
scanning step in the pipeline.

## Notable design decisions (interview talking points)

- **SSM Session Manager only** — no SSH keys, no bastion, no inbound 22
  anywhere in the lab. `org-baseline` creates the IAM role/instance
  profile; later phases attach it to EC2 instances.
- **Object Lock (COMPLIANCE mode, 400-day default)** on the log-archive
  bucket only — tamper-evidence for audit/assessor purposes. The
  Terraform *state* bucket deliberately does not use Object Lock, since
  state must remain mutable/deletable.
- **SCPs** deny leaving `us-east-1` (with an explicit allow-list of
  global/region-agnostic services like IAM, Organizations, Route 53,
  CloudFront, STS) and deny disabling CloudTrail or GuardDuty at the org
  level — enforced above the account, so no IAM policy inside an account
  can override it.
- **Budget alarm** at $50/mo (parameterized), with both an 80%/100%
  actual-spend notification and a 100%-forecasted early warning, all via
  SNS -> email.
- **VPC Flow Logs / ALB / WAF logging** are built as conditional
  (`enable_vpc_flow_logs`, etc.) in the `logging` module: the bucket,
  KMS key, and bucket policy are already wired to accept that traffic,
  but the actual flow-log/ALB/WAF resources are deferred until the
  workload VPC exists in a later phase — this was the explicit Phase 1
  scope call per `PLAN.md` (org trail + archive bucket is the Phase 1
  DoD, not the full workload log surface).
