FROM splunk/splunk:latest

# Splunkbase app 1876 — Splunk Add-on for Amazon Web Services.
# Downloaded manually from Splunkbase (requires a Splunk.com login) and
# placed next to this Dockerfile as splunk-ta-aws.tgz — the .tgz itself
# is gitignored, never committed.
USER root
COPY splunk-ta-aws.tgz /tmp/splunk-ta-aws.tgz
RUN mkdir -p $SPLUNK_HOME/etc/apps \
 && tar -xzf /tmp/splunk-ta-aws.tgz -C $SPLUNK_HOME/etc/apps \
 && rm /tmp/splunk-ta-aws.tgz \
 && chown -R splunk:splunk $SPLUNK_HOME/etc/apps
USER ansible
