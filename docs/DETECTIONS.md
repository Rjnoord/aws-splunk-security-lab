# Detection Use-Cases — SPL + ATT&CK mapping

Eight core detections. Each is a real business risk, a Splunk SPL exercise, and an AWS Security Specialty Domain 1 topic. SPL is written for the index layout in ARCHITECTURE.md §3. Tune thresholds/allowlists to your account before enabling as alerts.

> Convention: build each as a search first, validate against Phase 5 sim data, then Save As → Alert (scheduled cron, throttle by the entity field, action = SNS/email or the response Lambda).

---

## D1 — Root account usage
**Risk:** root should never be used operationally (PCI/SOC 2 finding). **ATT&CK:** T1078.004 Valid Accounts: Cloud.
```spl
index=aws_cloudtrail userIdentity.type=Root
    eventName!=ConsoleLogin OR (eventName=ConsoleLogin responseElements.ConsoleLogin=Success)
| stats count min(_time) as first max(_time) as last
    values(eventName) as actions by sourceIPAddress awsRegion
| convert ctime(first) ctime(last)
```
Alert if `count > 0`. Skill: `stats`, `values`, `convert`.

---

## D2 — Console login without MFA
**Risk:** credential compromise, MFA bypass. **ATT&CK:** T1078.
```spl
index=aws_cloudtrail eventName=ConsoleLogin
| search additionalEventData.MFAUsed=No responseElements.ConsoleLogin=Success
| stats count values(sourceIPAddress) as src by userIdentity.userName
```
Skill: field filtering on nested JSON, `stats by`.

---

## D3 — IAM policy / privilege escalation activity
**Risk:** attacker widening access. **ATT&CK:** T1098, T1548.
```spl
index=aws_cloudtrail
    (eventName=AttachUserPolicy OR eventName=PutUserPolicy OR eventName=CreatePolicyVersion
     OR eventName=AttachRolePolicy OR eventName=CreateAccessKey OR eventName=UpdateAssumeRolePolicy)
| table _time userIdentity.arn eventName requestParameters.policyArn sourceIPAddress
| sort - _time
```
Enrich with an allowlist of known admins (lookup). Skill: `table`, lookups.

---

## D4 — CloudTrail tampering (defense evasion)
**Risk:** attacker blinding the SOC. **ATT&CK:** T1562.001 Impair Defenses.
```spl
index=aws_cloudtrail
    (eventName=StopLogging OR eventName=DeleteTrail OR eventName=UpdateTrail
     OR eventName=PutEventSelectors)
| stats count by _time userIdentity.arn eventName requestParameters.name sourceIPAddress
```
**Highest-priority alert.** If logging stops, this is often the last event you'll see — pair with the response Lambda.

---

## D5 — GuardDuty high-severity finding
**Risk:** managed-threat-intel hit. **ATT&CK:** varies by finding.
```spl
index=aws_security source=*guardduty* severity>=7
| table _time title severity type resource.instanceDetails.instanceId
    service.action.actionType region
| sort - severity
```
Skill: numeric field comparison, working with findings JSON.

---

## D6 — API activity from an unusual region
**Risk:** account takeover often originates from a new region. **ATT&CK:** T1535.
```spl
index=aws_cloudtrail
| stats count by awsRegion userIdentity.arn
| eventstats sum(count) as total by userIdentity.arn
| eval pct=round(count/total*100,2)
| where awsRegion!="us-east-1" AND pct<5
```
Baselines per-principal region behavior. Skill: `eventstats`, `eval`, `where` — solid Power User material.

---

## D7 — S3 bucket made public (data exposure)
**Risk:** cardholder data exposure — the fintech nightmare. **ATT&CK:** T1530.
```spl
index=aws_cloudtrail
    (eventName=PutBucketPolicy OR eventName=PutBucketAcl
     OR eventName=PutBucketPublicAccessBlock OR eventName=DeletePublicAccessBlock)
| search requestParameters.*=*AllUsers* OR requestParameters.publicAccessBlockConfiguration.blockPublicAcls=false
| table _time userIdentity.arn eventName requestParameters.bucketName sourceIPAddress
```
Skill: wildcard field matching on nested request params.

---

## D8 — Potential data exfiltration signal
**Risk:** bulk read of the data store / large egress. **ATT&CK:** T1537, T1567.
```spl
index=aws_vpcflow action=ACCEPT
| stats sum(bytes) as total_bytes by src_ip dst_ip
| where total_bytes > 1073741824
| eval GB=round(total_bytes/1024/1024/1024,2)
| sort - GB
```
Combine with CloudTrail `GetObject`/`SelectObjectContent` spikes for higher fidelity. Skill: aggregation, byte math, thresholding.

---

## Dashboard panels (Phase 4)
- Findings by severity (last 24h) — `index=aws_security | timechart count by severity`
- Top eventNames — `index=aws_cloudtrail | top limit=15 eventName`
- Failed console logins by source IP + geo — `iplocation` + `geostats`
- API calls by region (choropleth) — `geostats count by awsRegion`
- Detection-hit timeline — summary index of alert fires
- Drilldown: click user → tokens `$user$` into an investigation panel showing their full CloudTrail timeline

## Detection-efficacy table (fill during Phase 5)
| ID | Technique | ATT&CK | Simulated how | Detected? | Time-to-alert |
|----|-----------|--------|---------------|-----------|---------------|
| D1 | Root usage | T1078.004 | | | |
| D4 | Stop CloudTrail | T1562.001 | | | |
| D7 | Public S3 | T1530 | | | |
| ...| | | | | |
