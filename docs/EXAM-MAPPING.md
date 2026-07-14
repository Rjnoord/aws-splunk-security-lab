# Exam Traceability Matrix

Proves the lab is not busywork — every phase feeds a graded exam objective. Use this to decide what to build before each exam date.

## AWS Certified Security – Specialty (SCS-C02)

| Domain (weight) | Lab coverage | Phase |
|---|---|---|
| **1. Threat Detection & Incident Response (14%)** | GuardDuty, detections D1–D8, attack sim, automated response Lambda | 4, 5, 6 |
| **2. Security Logging & Monitoring (18%)** | Org CloudTrail, VPC FL, dual ingestion patterns, Firehose failure handling, dashboards | 1, 3, 4 |
| **3. Infrastructure Security (20%)** | Private subnets, SSM (no bastion), SG design, WAF, ALB | 0, 2 |
| **4. Identity & Access Management (16%)** | Org/SCPs, cross-account log delivery, permission boundaries, Access Analyzer | 0, 1, 6 |
| **5. Data Protection (18%)** | KMS CMKs, S3 encryption + Object Lock, Secrets Manager, TLS-only policies | 1, 2 |
| **6. Management & Security Governance (14%)** | Security Hub aggregation, Config, Budgets, tagging | 1 |

Weakest-covered on paper: Domain 6 governance — add a Config conformance pack + tagging policy if you want fuller coverage.

## Splunk Core Certified User / Power User

| Objective | Lab coverage | Phase |
|---|---|---|
| Basic + advanced searching (SPL) | All D1–D8 detections | 4 |
| Fields, field extraction, sourcetypes | Add-on for AWS auto-extraction, nested JSON | 3, 4 |
| Transforming commands (`stats`, `chart`, `timechart`, `top`) | Dashboard panels, D6 `eventstats` | 4 |
| `eval` + `where` + calculated fields | D6, D8 byte math | 4 |
| Lookups | D3 admin allowlist enrichment | 4 |
| Reports & scheduled alerts | Every detection → scheduled alert | 4 |
| Dashboards + drilldowns + tokens | SOC + investigation dashboards | 4 |
| Indexes, retention, HEC, inputs | Index design, HEC, SQS-based S3 input | 2, 3 |

## Study sequencing recommendation
1. Do **Phases 0–3** to build muscle memory on logging/IAM/data-protection (SCS Domains 2–5, Splunk ingest).
2. Do **Phase 4** slowly — it's the bulk of Splunk Core *and* SCS Domain 1, the hardest to learn from books.
3. Phases 5–6 right before the SCS exam — incident response scenarios are heavily tested and stick better after you've done them.
