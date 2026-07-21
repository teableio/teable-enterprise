#!/usr/bin/env bash
set -euo pipefail

: "${TEABLE_API_TOKEN:?TEABLE_API_TOKEN is required}"
: "${REGION:?REGION is required}"
: "${IMAGE_TAG:?IMAGE_TAG is required}"

TEABLE_API_BASE="https://app.teable.ai/api"
RELEASES_TABLE_ID="tblAhVLOxNtvkaF1ii5"
LAUNCHES_TABLE_ID="tblmGAFOHrGcy66PaUp"

case "$REGION" in
  teable.ai) target="ai" ;;
  teable.cn) target="cn" ;;
  *) echo "Unsupported region: $REGION"; exit 1 ;;
esac

operation_type="${OPERATION_TYPE:-Release}"
if [ "$operation_type" != "Release" ] && [ "$operation_type" != "Rollback" ]; then
  echo "Unsupported operation type: $operation_type"
  exit 1
fi

if [ -n "${RELEASE_RECORD_ID:-}" ] && [ -n "${PUBLISH_LOCK_ID:-}" ]; then
  read_http_code=$(curl -sS -w "%{http_code}" -o /tmp/release-lock.json \
    "${TEABLE_API_BASE}/table/${RELEASES_TABLE_ID}/record/${RELEASE_RECORD_ID}?fieldKeyType=dbFieldName" \
    -H "Authorization: Bearer ${TEABLE_API_TOKEN}")

  if [ "$read_http_code" -lt 200 ] || [ "$read_http_code" -ge 300 ]; then
    echo "Failed to read Release publishing metadata: HTTP ${read_http_code}"
    cat /tmp/release-lock.json
    exit 1
  fi

  release_metadata=$(jq -cer '.fields.Publishing_Metadata | fromjson' /tmp/release-lock.json) || {
    echo "Release publishing metadata is missing or invalid"
    exit 1
  }
  current_lock_id=$(jq -r '.lockId // empty' <<<"$release_metadata")
  current_state=$(jq -r '.state // empty' <<<"$release_metadata")
  target_is_locked=$(jq -r --arg target "$target" '(.targets // []) | index($target) != null' <<<"$release_metadata")
  already_completed=$(jq -r --arg target "$target" \
    '(((.launchedTargets // []) + (.completedTargets // [])) | unique) | index($target) != null' \
    <<<"$release_metadata")

  if [ "$already_completed" = "true" ]; then
    echo "${REGION} is already recorded for publishing lock ${PUBLISH_LOCK_ID}"
    exit 0
  fi

  if [ "$current_state" != "launching" ] || [ "$current_lock_id" != "$PUBLISH_LOCK_ID" ] || [ "$target_is_locked" != "true" ]; then
    echo "Release publishing lock no longer authorizes ${REGION}"
    exit 1
  fi
fi

current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
related_release_ids_json=$(printf '%s' "${RELATED_RELEASE_RECORD_IDS:-}" | \
  jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')

payload=$(jq -n \
  --arg date "$current_time" \
  --arg region "$REGION" \
  --arg trigger "${TRIGGER:-Manual}" \
  --arg imageTag "$IMAGE_TAG" \
  --arg snapshot "${RELEASE_CREATED_TIME:-}" \
  --arg refinedChangelog "${REFINED_CHANGELOG:-}" \
  --arg refinedChangelogZh "${REFINED_CHANGELOG_ZH:-}" \
  --arg operationType "$operation_type" \
  --argjson relatedReleaseIds "$related_release_ids_json" \
  '{
    "fieldKeyType": "dbFieldName",
    "typecast": true,
    "records": [
      {
        "fields": {
          "date": $date,
          "region": $region,
          "trigger": $trigger,
          "EE_Lanched_Release": $imageTag,
          "Deploy_snapshot_time": (if $snapshot != "" then $snapshot else null end),
          "Related_Releases": (if ($relatedReleaseIds | length) > 0 then $relatedReleaseIds else null end),
          "Refined_Changelog": (if $refinedChangelog != "" then $refinedChangelog else null end),
          "Refined_Changelog_Zhong_Wen": (if $refinedChangelogZh != "" then $refinedChangelogZh else null end),
          "Operation_Type": $operationType,
          "Rollback_Status": (if $operationType == "Rollback" then "Succeeded" else null end)
        }
      }
    ]
  }')

create_http_code=$(curl -sS -w "%{http_code}" -o /tmp/launch-create.json -X POST \
  "${TEABLE_API_BASE}/table/${LAUNCHES_TABLE_ID}/record" \
  -H "Authorization: Bearer ${TEABLE_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$payload")

if [ "$create_http_code" -lt 200 ] || [ "$create_http_code" -ge 300 ]; then
  echo "Failed to create ${REGION} Launch: HTTP ${create_http_code}"
  cat /tmp/launch-create.json
  exit 1
fi

launch_record_id=$(jq -r '.records[0].id // empty' /tmp/launch-create.json)
echo "Created ${REGION} Launch ${launch_record_id}"
