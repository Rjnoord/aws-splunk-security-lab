# AWS + Splunk Security Lab — "Meridian Pay" SOC Build

A senior-level, business-anchored home lab that doubles as exam prep for **AWS Certified Security – Specialty (SCS-C02)** and **Splunk Core Certified User / Power User**.

You are the founding security engineer for **Meridian Pay**, a fictional mid-size fintech running a payments API on AWS. Meridian is pursuing **PCI-DSS** and **SOC 2 Type II**. Your job: stand up a cloud-native detection & response capability with Splunk as the SIEM, prove you can detect and respond to real attack patterns, and produce audit-ready evidence.

This framing matters — every component maps to a business driver (compliance, fraud, availability, insider risk) *and* to an exam objective. That is what makes it a portfolio piece, not a tutorial.

## What this lab demonstrates

| Business need | Lab capability | Cert coverage |
|---|---|---|
| Prove control effectiveness to auditors | Centralized logging + retention + dashboards | SCS Domain 2, Splunk reports/dashboards |
| Detect account compromise / fraud | Correlation searches on CloudTrail + GuardDuty | SCS Domain 1, Splunk SPL |
| Contain incidents fast | EventBridge → Lambda automated response | SCS Domain 1 |
| Least-privilege access | IAM boundaries, SCPs, access analyzer | SCS Domain 3 & 4 |
| Protect cardholder data | KMS, S3 encryption, secrets management | SCS Domain 5 |

## Repo layout

```
.
├── README.md              # you are here
├── docs/
│   ├── ARCHITECTURE.md    # the senior-level design (diagram, data flows, decisions)
│   ├── PLAN.md            # phased build plan with exit criteria
│   ├── DETECTIONS.md      # detection use-cases + SPL + ATT&CK mapping
│   └── EXAM-MAPPING.md    # traceability: lab task -> exam objective
├── terraform/             # IaC for AWS side (built in Phase 2+)
├── splunk/                # SPL searches, dashboards, props/transforms
└── runbooks/              # incident response runbooks
```

## How to use it

Work the phases in `docs/PLAN.md` in order. Each phase has a **definition of done** and a **cost checkpoint**. Don't skip ahead — later detections depend on earlier data sources being live.

> Cost note: this lab uses paid services (EC2 for Splunk, GuardDuty, Kinesis Firehose). Estimated run cost is tracked per-phase in PLAN.md. Tear down with the janitor workflow between sessions.
