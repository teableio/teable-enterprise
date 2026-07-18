#!/usr/bin/env bash
set -euo pipefail

: "${TEABLE_API_TOKEN:?TEABLE_API_TOKEN is required}"
: "${RELEASE_RECORD_ID:?RELEASE_RECORD_ID is required}"
: "${PUBLISH_LOCK_ID:?PUBLISH_LOCK_ID is required}"
: "${TARGET:?TARGET is required}"

if [ "$TARGET" != "ai" ] && [ "$TARGET" != "cn" ]; then
  echo "Unsupported target: $TARGET"
  exit 1
fi

TEABLE_API_BASE="https://app.teable.ai/api"
RELEASES_TABLE_ID="tblAhVLOxNtvkaF1ii5"

read_http_code=$(curl -sS -w "%{http_code}" -o /tmp/release-lock.json \
  "${TEABLE_API_BASE}/table/${RELEASES_TABLE_ID}/record/${RELEASE_RECORD_ID}?fieldKeyType=dbFieldName" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}")

if [ "$read_http_code" -lt 200 ] || [ "$read_http_code" -ge 300 ]; then
  echo "Failed to read Release publishing metadata: HTTP ${read_http_code}"
  cat /tmp/release-lock.json
  exit 1
fi

release_metadata=$(jq -cer '.fields.Publishing_Metadata | fromjson' /tmp/release-lock.json) || {
  current_status=$(jq -r '.fields.status // empty' /tmp/release-lock.json)
  if [ "$current_status" = "Launched" ]; then
    echo "Release is already fully launched"
    exit 0
  fi
  echo "Release publishing metadata is missing or invalid"
  exit 1
}

current_lock_id=$(jq -r '.lockId // empty' <<<"$release_metadata")
current_state=$(jq -r '.state // empty' <<<"$release_metadata")
if [ "$current_state" != "launching" ] || [ "$current_lock_id" != "$PUBLISH_LOCK_ID" ]; then
  echo "Publishing lock changed before ${TARGET} completion was recorded"
  exit 1
fi

current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
completed_metadata=$(jq -c --arg target "$TARGET" \
  '.completedTargets = (((.completedTargets // []) + [$target]) | unique)' \
  <<<"$release_metadata")
launched_targets=$(jq -c --arg target "$TARGET" \
  '((.launchedTargets // []) + (.completedTargets // []) + [$target]) | unique' \
  <<<"$release_metadata")
all_launched=$(jq -r 'index("ai") != null and index("cn") != null' <<<"$launched_targets")
has_pending_lock_target=$(jq -r --argjson launched "$launched_targets" \
  'any((.targets // [])[]; . as $target | ($launched | index($target)) == null)' \
  <<<"$release_metadata")

if [ "$all_launched" = "true" ]; then
  release_status="Launched"
  publishing_metadata="null"
elif [ "$has_pending_lock_target" = "true" ]; then
  release_status="Launching"
  publishing_metadata=$(jq -Rn --arg value "$completed_metadata" '$value')
else
  release_status="Released"
  idle_metadata=$(jq -cn \
    --argjson launchedTargets "$launched_targets" \
    --arg updatedAt "$current_time" \
    '{version: 1, state: "idle", launchedTargets: $launchedTargets, updatedAt: $updatedAt}')
  publishing_metadata=$(jq -Rn --arg value "$idle_metadata" '$value')
fi

update_payload=$(jq -n \
  --arg status "$release_status" \
  --argjson metadata "$publishing_metadata" \
  '{
    "fieldKeyType": "dbFieldName",
    "typecast": true,
    "record": {
      "fields": {
        "status": $status,
        "Publishing_Metadata": $metadata
      }
    }
  }')

update_http_code=$(curl -sS -w "%{http_code}" -o /tmp/release-update.json -X PATCH \
  "${TEABLE_API_BASE}/table/${RELEASES_TABLE_ID}/record/${RELEASE_RECORD_ID}" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$update_payload")

if [ "$update_http_code" -lt 200 ] || [ "$update_http_code" -ge 300 ]; then
  echo "Failed to update Release progress: HTTP ${update_http_code}"
  cat /tmp/release-update.json
  exit 1
fi

echo "Updated Release ${RELEASE_RECORD_ID} to ${release_status}; launched targets: ${launched_targets}"
