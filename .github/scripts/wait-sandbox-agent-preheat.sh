#!/usr/bin/env bash
# Hold a launch until every sandbox node has this release's sandbox-agent
# image, so the first sandboxes the new app version spawns don't pull ~900MB
# themselves (on 2026-11-17 that took 64s and turned the status probe red).
#
# Reads the infra service preheat status (GET /api/image-preheats): ready
# means the preheat targets <image> and readyNodes == desiredNodes, counted
# from the image list each node reports.
#
# Best-effort, always exits 0: on timeout, an API error, or a preheat that
# points at another image for a minute (the preheat call failed, or something
# else re-pointed it), it warns and lets the rollout go ahead. A cold node
# only costs first-spawn latency; it must never hold a release back.
#
# Usage: wait-sandbox-agent-preheat.sh <infra base url> <image>
# Env:   PREHEAT_TOKEN         infra preheat API token
#        PREHEAT_WAIT_SECONDS  overall limit (default 300)
set -uo pipefail

base_url="${1:?infra base url required}"
image="${2:?image required}"
wait_seconds="${PREHEAT_WAIT_SECONDS:-300}"
poll_seconds=10
max_mismatch_polls=6

if [ -z "${PREHEAT_TOKEN:-}" ]; then
  echo "::warning::no preheat token, not waiting for the sandbox agent preheat"
  exit 0
fi

deadline=$(( $(date +%s) + wait_seconds ))
mismatch_polls=0

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

while :; do
  code="$(curl -sS --max-time 20 -o "$body_file" -w '%{http_code}' \
    -H "Authorization: Bearer ${PREHEAT_TOKEN}" \
    "${base_url}/api/image-preheats")" || code="000"
  case "$code" in
    401|403)
      echo "::warning::preheat status API rejected the token (HTTP ${code}), not waiting for the sandbox agent preheat"
      exit 0 ;;
    2??)
      state="$(jq -r --arg image "$image" '
        .current as $c
        | if $c == null then "mismatch: no preheat set"
          elif $c.image != $image then "mismatch: preheat targets \($c.image)"
          elif $c.readyNodes >= $c.desiredNodes then "ready: \($c.readyNodes)/\($c.desiredNodes) nodes cached"
          else "pulling: \($c.readyNodes)/\($c.desiredNodes) nodes cached, \($c.failedNodes) failed"
          end' "$body_file")" || state="error: unreadable preheat status" ;;
    *) state="error: preheat status HTTP ${code}" ;;
  esac
  echo "$(date -u +%H:%M:%S) ${state}"

  case "$state" in
    ready:*) exit 0 ;;
    mismatch:*) mismatch_polls=$(( mismatch_polls + 1 )) ;;
    *) mismatch_polls=0 ;;
  esac

  if [ "$mismatch_polls" -ge "$max_mismatch_polls" ]; then
    echo "::warning::sandbox agent preheat is not on ${image} (${state#mismatch: }); rolling out without waiting"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::warning::sandbox agent preheat not complete after ${wait_seconds}s (${state}); rolling out anyway, uncached nodes pull the image on first spawn"
    exit 0
  fi
  sleep "$poll_seconds"
done
