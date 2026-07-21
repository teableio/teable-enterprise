#!/usr/bin/env bash
set -euo pipefail

: "${TEABLE_API_TOKEN:?TEABLE_API_TOKEN is required}"
: "${SOURCE_LAUNCH_ID:?SOURCE_LAUNCH_ID is required}"
: "${ROLLBACK_LOCK_ID:?ROLLBACK_LOCK_ID is required}"
: "${REGION:?REGION is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

TEABLE_API_BASE="https://app.teable.ai/api"
LAUNCHES_TABLE_ID="tblmGAFOHrGcy66PaUp"

read_http_code=$(curl -sS -w "%{http_code}" -o /tmp/rollback-source-launch.json \
  "${TEABLE_API_BASE}/table/${LAUNCHES_TABLE_ID}/record/${SOURCE_LAUNCH_ID}?fieldKeyType=dbFieldName" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}")

if [ "$read_http_code" -lt 200 ] || [ "$read_http_code" -ge 300 ]; then
  echo "Failed to read rollback source Launch: HTTP ${read_http_code}"
  cat /tmp/rollback-source-launch.json
  exit 1
fi

rollback_metadata=$(jq -cer '.fields.Rollback_Metadata | fromjson' /tmp/rollback-source-launch.json) || {
  echo "Rollback metadata is missing or invalid"
  exit 1
}

current_state=$(jq -r '.state // empty' <<<"$rollback_metadata")
current_lock_id=$(jq -r '.lockId // empty' <<<"$rollback_metadata")
current_region=$(jq -r '.region // empty' <<<"$rollback_metadata")
current_image_tag=$(jq -r '.imageTag // empty' <<<"$rollback_metadata")
expires_at=$(jq -r '.expiresAt // empty' <<<"$rollback_metadata")

if [ "$current_state" != "rolling_back" ] || \
   [ "$current_lock_id" != "$ROLLBACK_LOCK_ID" ] || \
   [ "$current_region" != "$REGION" ] || \
   [ "$current_image_tag" != "$IMAGE_TAG" ]; then
  echo "Rollback lock no longer authorizes ${REGION} ${IMAGE_TAG}"
  exit 1
fi

expires_epoch=$(date -u -d "$expires_at" +%s 2>/dev/null || echo 0)
if [ "$expires_epoch" -le "$(date -u +%s)" ]; then
  echo "Rollback lock expired at ${expires_at}"
  exit 1
fi

echo "Validated rollback lock ${ROLLBACK_LOCK_ID} for ${REGION} ${IMAGE_TAG}"
