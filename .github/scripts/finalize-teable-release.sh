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

mark_covered_releases_launched() {
  local covered_release_ids update_payload update_http_code
  covered_release_ids=$(printf '%s' "${RELATED_RELEASE_RECORD_IDS:-}" | jq -Rc \
    --arg target "$RELEASE_RECORD_ID" \
    'split(",")
     | map(gsub("^\\s+|\\s+$"; ""))
     | . + [$target]
     | map(select(test("^rec[A-Za-z0-9]+$")))
     | unique')
  update_payload=$(jq -n \
    --argjson recordIds "$covered_release_ids" \
    '{
      "fieldKeyType": "dbFieldName",
      "typecast": true,
      "records": ($recordIds | map({
        "id": .,
        "fields": {
          "status": "Launched",
          "Publishing_Metadata": null
        }
      }))
    }')
  update_http_code=$(curl -sS -w "%{http_code}" -o /tmp/release-update.json -X PATCH \
    "${TEABLE_API_BASE}/table/${RELEASES_TABLE_ID}/record" \
    -H "Authorization: Bearer ${TEABLE_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$update_payload")

  if [ "$update_http_code" -lt 200 ] || [ "$update_http_code" -ge 300 ]; then
    echo "Failed to mark covered Releases as Launched: HTTP ${update_http_code}"
    cat /tmp/release-update.json
    exit 1
  fi

  echo "Marked covered Releases ${covered_release_ids} as Launched"
}

read_http_code=$(curl -sS -w "%{http_code}" -o /tmp/release-lock.json \
  "${TEABLE_API_BASE}/table/${RELEASES_TABLE_ID}/record/${RELEASE_RECORD_ID}?fieldKeyType=dbFieldName" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}")

if [ "$read_http_code" -lt 200 ] || [ "$read_http_code" -ge 300 ]; then
  echo "Failed to read Release publishing metadata: HTTP ${read_http_code}"
  cat /tmp/release-lock.json
  exit 1
fi

release_metadata=$(jq -cer '.fields.Publishing_Metadata | strings | try fromjson' /tmp/release-lock.json) || {
  current_status=$(jq -r '.fields.status // empty' /tmp/release-lock.json)
  if [ "$current_status" = "Launched" ]; then
    mark_covered_releases_launched
    echo "Release was already fully launched; coverage reconciled"
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
  '.completedTargets = (((.completedTargets // []) + [$target]) | unique)
   | .failedTargets = ((.failedTargets // []) | map(select(. != $target)))
   | if .lastFailure.target == $target then del(.lastFailure) else . end' \
  <<<"$release_metadata")
launched_targets=$(jq -c \
  '((.launchedTargets // []) + (.completedTargets // [])) | unique' \
  <<<"$completed_metadata")
terminal_targets=$(jq -c \
  '((.launchedTargets // []) + (.completedTargets // []) + (.failedTargets // [])) | unique' \
  <<<"$completed_metadata")
all_launched=$(jq -r 'index("ai") != null and index("cn") != null' <<<"$launched_targets")
has_pending_lock_target=$(jq -r --argjson terminal "$terminal_targets" \
  'any((.targets // [])[]; . as $target | ($terminal | index($target)) == null)' \
  <<<"$completed_metadata")

if [ "$all_launched" = "true" ]; then
  mark_covered_releases_launched
  echo "Launched targets: ${launched_targets}"
  exit 0
elif [ "$has_pending_lock_target" = "true" ]; then
  release_status="Launching"
  publishing_metadata=$(jq -Rn --arg value "$completed_metadata" '$value')
else
  release_status="Released"
  idle_metadata=$(jq -cn \
    --argjson launchedTargets "$launched_targets" \
    --argjson lastFailure "$(jq -c '.lastFailure // null' <<<"$completed_metadata")" \
    --arg updatedAt "$current_time" \
    '{version: 1, state: "idle", launchedTargets: $launchedTargets, updatedAt: $updatedAt}
     + if $lastFailure == null then {} else {lastFailure: $lastFailure} end')
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
