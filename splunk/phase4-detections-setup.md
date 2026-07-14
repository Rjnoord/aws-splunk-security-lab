# Phase 4 — Detections & dashboards setup

Scope: packages the 8 detection alerts (D1-D8, SPL in `docs/DETECTIONS.md`),
the SOC Overview dashboard, and the investigation drilldown dashboard as a
proper Splunk app: `splunk/apps/aws_security_lab/`. Built the same way
Phase 3's TA install was handled -- as files in this repo, not as live edits
made directly against the running container. **Nothing in this app has been
deployed to the container yet.**

## 1. Deploy the app into the running local container

The container (`splunk`, per `splunk/README.md` Phase 2 / `splunk/phase3-pattern-a-setup.md`)
uses named volumes (`splunk-etc`, `splunk-var`) for `/opt/splunk/etc` and
`/opt/splunk/var`. Apps copied into `etc/apps` on a named volume persist
across restarts (unlike Phase 3's TA, which needed baking into the image
because it required a rebuild-surviving install of a third-party download --
this app is just our own config files, so a straight `docker cp` + restart
is sufficient and matches how RJ would push updates to it going forward):

```bash
# From the repo root, with the `splunk` container already running:
docker cp splunk/apps/aws_security_lab splunk:/opt/splunk/etc/apps/aws_security_lab

# Splunk runs as the `splunk` user inside the container -- fix ownership
# after the copy or Splunk will refuse to load the app's confs:
docker exec -u root splunk chown -R splunk:splunk /opt/splunk/etc/apps/aws_security_lab

docker restart splunk
```

Confirm it loaded: Splunk Web (`https://localhost:8000`) -> Apps -> should
list **AWS Security Lab — Detections**. Confirm the 8 alerts exist under
**Settings -> Searches, reports, and alerts** (app filter: `aws_security_lab`),
and the two dashboards exist under **Settings -> User interface -> Views**
(or just find them in the app's dashboard list): `SOC Overview` and
`Investigation`.

## 2. The one manual step RJ must do himself: SMTP + email addresses

None of the four email-enabled alerts (D1, D4, D5, D7) will actually send
mail until both of these are done -- deliberately not automated here, since
neither belongs in version control:

1. **Configure SMTP.** Splunk Web -> **Settings -> Server Settings -> Email
   Settings**. Point it at whatever mail relay/account you want alerts to
   come from (a personal Gmail app-password SMTP relay is the common
   homelab choice). This is a one-time, instance-level setting -- it is not
   part of this app and is not in any file in this repo.

2. **Fill in the real recipient address.** Every email-enabled alert in
   `savedsearches.conf` ships with a placeholder:
   ```
   action.email.to = $email$
   ```
   `$email$` is not a real token Splunk will resolve on its own here -- it's
   a deliberate placeholder marking "fill this in," not functioning
   token substitution. Don't edit `default/savedsearches.conf` directly to
   add your address (that's the versioned app config everyone/every future
   clone gets). Instead use Splunk's standard **default/local override**
   convention:

   - Anything under an app's `default/` directory is the versioned,
     "factory" config (what's in this repo).
   - Anything under the app's `local/` directory (created automatically by
     Splunk Web edits, or by hand) overrides the matching stanza in
     `default/` at runtime, and is where instance-specific values belong.
   - `local/` is not committed -- add `splunk/apps/*/local/` to `.gitignore`
     if it isn't already covered, so a real email address never ends up in
     git.

   Easiest path: in Splunk Web, open each of the 4 email alerts (D1, D4,
   D5, D7) under **Settings -> Searches, reports, and alerts -> Edit ->
   Edit Actions**, and set the "To" address there. Splunk writes that into
   `etc/apps/aws_security_lab/local/savedsearches.conf` automatically --
   you don't need to hand-edit anything inside the container.

   Alternatively, hand-write a `local/savedsearches.conf` stanza that only
   overrides the one field, e.g.:
   ```
   [D1 - Root Account Usage]
   action.email.to = you@example.com
   ```
   and `docker cp` just that file in the same way as step 1, restart, done.

## 3. Phase 4 DoD validation (full validation happens in Phase 5)

Per `docs/PLAN.md`, Phase 4's DoD is: *"you can trigger each detection with
a controlled action (Phase 5), see the alert fire, and pivot in the
dashboard."* The controlled-action triggering itself is Phase 5 scope
(attack simulation) -- what to confirm now, with what's already live:

- [ ] All 8 saved searches appear enabled (`disabled = 0`) and scheduled
      in Splunk Web, with the cron intervals from `savedsearches.conf`.
- [ ] `index=summary_detections | stats count by detection_id` returns
      rows once at least one alert has fired on real data (D1-D4, D6, D7
      should start populating as soon as Phase 3 Pattern A CloudTrail
      ingestion is live and real API activity happens; D5/D8 will stay
      empty until Pattern B / VPC Flow Logs are enabled).
- [ ] `SOC Overview` dashboard renders all 5 panels without search errors
      (empty results are fine and expected pre-Phase-5/pre-Pattern-B;
      actual search errors are not).
- [ ] `Investigation` dashboard's base panel lists users, clicking a row
      sets `$user$` and populates the second panel with that user's
      CloudTrail timeline.
- [ ] (Phase 5, later) Trigger each detection with a controlled/simulated
      action, confirm the alert fires, confirm it lands in
      `summary_detections`, confirm it's visible on `SOC Overview`, and
      fill in the detection-efficacy table in `docs/DETECTIONS.md`.
