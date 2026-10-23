#!/usr/bin/env bash
# Uptime check on /health plus an e-mail alert after 10 minutes of failure.
# Creates three things in the GCP project bibliostatus-app (Cloud Monitoring):
#   1. an e-mail notification channel
#   2. an uptime check: GET https://bibliostatus.youcanbeapirate.com/health every 5 minutes
#   3. an alert policy: e-mail when the check has failed for 10 minutes
# Uses the REST API (the gcloud alpha component is not installed).
# Not idempotent: running it twice creates duplicates.
set -euo pipefail

PROJECT=bibliostatus-app
HOST=bibliostatus.youcanbeapirate.com
EMAIL=anttilennartrask@gmail.com
API=https://monitoring.googleapis.com/v3/projects/$PROJECT
TOKEN=$(gcloud auth print-access-token)

post() { curl -sS --fail-with-body -X POST "$API/$1" \
  -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT" \
  -H "Content-Type: application/json" -d "$2"; }

CHANNEL=$(post notificationChannels '{
  "type": "email",
  "displayName": "BiblioStatus alerts",
  "labels": {"email_address": "'"$EMAIL"'"}
}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"])')
echo "channel: $CHANNEL"

CHECK=$(post uptimeCheckConfigs '{
  "displayName": "BiblioStatus /health",
  "monitoredResource": {"type": "uptime_url",
    "labels": {"project_id": "'"$PROJECT"'", "host": "'"$HOST"'"}},
  "httpCheck": {"path": "/health", "port": 443, "useSsl": true, "validateSsl": true,
    "requestMethod": "GET"},
  "contentMatchers": [{"content": "ok", "matcher": "MATCHES_REGEX"}],
  "period": "300s",
  "timeout": "10s"
}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["name"].split("/")[-1])')
echo "uptime check id: $CHECK"

post alertPolicies '{
  "displayName": "BiblioStatus /health failing",
  "combiner": "OR",
  "notificationChannels": ["'"$CHANNEL"'"],
  "conditions": [{
    "displayName": "/health failed for 10 minutes",
    "conditionThreshold": {
      "filter": "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"'"$CHECK"'\" AND resource.type=\"uptime_url\"",
      "comparison": "COMPARISON_GT",
      "thresholdValue": 1,
      "duration": "600s",
      "aggregations": [{
        "alignmentPeriod": "1200s",
        "perSeriesAligner": "ALIGN_NEXT_OLDER",
        "crossSeriesReducer": "REDUCE_COUNT_FALSE",
        "groupByFields": ["resource.label.*"]
      }]
    }
  }]
}' >/dev/null
echo "alert policy created"
