#!/usr/bin/env bash
set -euo pipefail

: "${TEABLE_API_TOKEN:?TEABLE_API_TOKEN is required}"
: "${SOURCE_LAUNCH_ID:?SOURCE_LAUNCH_ID is required}"
: "${ROLLBACK_LOCK_ID:?ROLLBACK_LOCK_ID is required}"

TEABLE_API_BASE="https://app.teable.ai/api"
LAUNCHES_TABLE_ID="tblmGAFOHrGcy66PaUp"

read_http_code=$(curl -sS -w "%{http_code}" -o /tmp/rollback-source-launch.json \
  "${TEABLE_API_BASE}/table/${LAUNCHES_TABLE_ID}/record/${SOURCE_LAUNCH_ID}?fieldKeyType=dbFieldName" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}")

if [ "$read_http_code" -lt 200 ] || [ "$read_http_code" -ge 300 ]; then
  echo "Failed to read rollback source Launch: HTTP ${read_http_code}"
  exit 1
fi

rollback_metadata=$(jq -cer '.fields.Rollback_Metadata | fromjson' /tmp/rollback-source-launch.json) || exit 0
current_lock_id=$(jq -r '.lockId // empty' <<<"$rollback_metadata")
if [ "$current_lock_id" != "$ROLLBACK_LOCK_ID" ]; then
  echo "Rollback lock changed; failure status was not written"
  exit 0
fi

failed_at=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
failed_metadata=$(jq -c \
  --arg failedAt "$failed_at" \
  --arg error "${ERROR_SUMMARY:-GitHub Actions rollback failed}" \
  '.failedAt = $failedAt | .lastError = $error' \
  <<<"$rollback_metadata")

update_payload=$(jq -n \
  --arg status "Failed" \
  --arg metadata "$failed_metadata" \
  '{
    "fieldKeyType": "dbFieldName",
    "typecast": true,
    "record": {
      "fields": {
        "Rollback_Status": $status,
        "Rollback_Metadata": $metadata
      }
    }
  }')

update_http_code=$(curl -sS -w "%{http_code}" -o /tmp/rollback-source-update.json -X PATCH \
  "${TEABLE_API_BASE}/table/${LAUNCHES_TABLE_ID}/record/${SOURCE_LAUNCH_ID}" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$update_payload")

if [ "$update_http_code" -lt 200 ] || [ "$update_http_code" -ge 300 ]; then
  echo "Failed to mark rollback as failed: HTTP ${update_http_code}"
  cat /tmp/rollback-source-update.json
  exit 1
fi

echo "Marked rollback ${ROLLBACK_LOCK_ID} as failed; lock remains until expiry"
