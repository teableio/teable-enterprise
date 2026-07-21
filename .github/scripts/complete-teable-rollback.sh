#!/usr/bin/env bash
set -euo pipefail

: "${TEABLE_API_TOKEN:?TEABLE_API_TOKEN is required}"
: "${SOURCE_LAUNCH_ID:?SOURCE_LAUNCH_ID is required}"
: "${ROLLBACK_LOCK_ID:?ROLLBACK_LOCK_ID is required}"
: "${REGION:?REGION is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

TEABLE_API_BASE="https://app.teable.ai/api"
LAUNCHES_TABLE_ID="tblmGAFOHrGcy66PaUp"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

bash "${SCRIPT_DIR}/validate-teable-rollback.sh"

export OPERATION_TYPE="Rollback"
export RELEASE_CREATED_TIME=$(jq -r '.fields.Deploy_snapshot_time // empty' /tmp/rollback-source-launch.json)
export RELATED_RELEASE_RECORD_IDS=$(jq -r \
  '(.fields.Related_Releases // []) | map(if type == "object" then .id else . end) | map(select(type == "string" and length > 0)) | join(",")' \
  /tmp/rollback-source-launch.json)
export REFINED_CHANGELOG=$(jq -r '.fields.Refined_Changelog // empty' /tmp/rollback-source-launch.json)
export REFINED_CHANGELOG_ZH=$(jq -r '.fields.Refined_Changelog_Zhong_Wen // empty' /tmp/rollback-source-launch.json)
unset PUBLISH_LOCK_ID
unset RELEASE_RECORD_ID
bash "${SCRIPT_DIR}/record-teable-launch.sh"

completed_at=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
update_payload=$(jq -n \
  --arg status "Succeeded" \
  '{
    "fieldKeyType": "dbFieldName",
    "typecast": true,
    "record": {
      "fields": {
        "Rollback_Status": $status,
        "Rollback_Metadata": null
      }
    }
  }')

update_http_code=$(curl -sS -w "%{http_code}" -o /tmp/rollback-source-update.json -X PATCH \
  "${TEABLE_API_BASE}/table/${LAUNCHES_TABLE_ID}/record/${SOURCE_LAUNCH_ID}" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$update_payload")

if [ "$update_http_code" -lt 200 ] || [ "$update_http_code" -ge 300 ]; then
  echo "Rollback deployed but source Launch status update failed: HTTP ${update_http_code}"
  cat /tmp/rollback-source-update.json
  exit 1
fi

echo "Completed ${REGION} + EE latest rollback to ${IMAGE_TAG} at ${completed_at}"
