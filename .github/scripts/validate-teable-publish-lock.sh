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
  echo "::error::Release publishing lock is no longer active. Retry ${TARGET} from Release Publisher to acquire a new global lock; do not rerun this Actions run."
  exit 1
}

current_lock_id=$(jq -r '.lockId // empty' <<<"$release_metadata")
current_state=$(jq -r '.state // empty' <<<"$release_metadata")
target_is_locked=$(jq -r --arg target "$TARGET" \
  '(.targets // []) | index($target) != null' <<<"$release_metadata")
already_completed=$(jq -r --arg target "$TARGET" \
  '(((.launchedTargets // []) + (.completedTargets // [])) | unique) | index($target) != null' \
  <<<"$release_metadata")

if [ "$already_completed" = "true" ]; then
  echo "::notice::${TARGET} is already completed for this Release"
  exit 0
fi

if [ "$current_state" != "launching" ] || \
   [ "$current_lock_id" != "$PUBLISH_LOCK_ID" ] || \
   [ "$target_is_locked" != "true" ]; then
  echo "::error::Release publishing lock no longer authorizes ${TARGET}. Retry from Release Publisher to acquire a new global lock; do not rerun this Actions run."
  exit 1
fi

echo "Validated ${TARGET} publishing lock ${PUBLISH_LOCK_ID}"
