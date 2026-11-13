#!/usr/bin/env bash
# Copy one image to Aliyun ACR (registry.cn-shenzhen) through the Hong Kong relay.
#
#   .github/scripts/acr-relay-copy.sh <src> <dst> <amd64|all> [ghcr-token]
#
# GitHub runners reach Shenzhen across the border, and since 2026-10-29 a single connection there
# often drops to ~200 KB/s: the ~360 MB node_modules layer could not finish within 40 minutes and
# the 2026-11-11/12 launches timed out. The relay (teableio/teable-infra:
# terraform/deployments/aliyun-acr-relay-hk) is 15 ms from Shenzhen and pushes at ~3.5 MB/s per
# connection, so the copy runs there: this script invokes the relay's Cloud Assistant command
# acr-relay-copy and waits for it. The relay holds the ACR push credential. A ghcr token, when
# given, is used for that single pull only; pass the job's GITHUB_TOKEN, which expires with the job.
# The relay accepts only teableio sources on ghcr.io / docker.io and destinations under
# registry.cn-shenzhen.aliyuncs.com/teable. If the relay itself is unusable, the copy falls back
# to running on this runner (see direct_copy).
#
# Credentials: ALIBABA_CLOUD_ACCESS_KEY_ID / _SECRET / _SECURITY_TOKEN from aliyun-oidc-login.sh run
# with the relay role (ACR_RELAY_ROLE_ARN), which may invoke only that command on that instance.
set -euo pipefail

src="${1:?usage: acr-relay-copy.sh <src> <dst> <amd64|all> [ghcr-token]}"
dst="${2:?}"
arch="${3:?}"
token="${4:-}"
region="${ACR_RELAY_REGION:-cn-hongkong}"
instance="${ACR_RELAY_INSTANCE_ID:?}"
: "${ALIBABA_CLOUD_ACCESS_KEY_ID:?}" "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:?}" "${ALIBABA_CLOUD_SECURITY_TOKEN:?}"

# STS credentials go into a private CLI config file, never onto a command line (same as
# aliyun-kube-tunnel.sh). The ghcr token does end up in InvokeCommand's arguments: the API takes
# parameters inline. The runner is single-job and the token dies with the job.
cfg="$(mktemp)"
trap 'rm -f "${cfg}"' EXIT
( umask 077
  jq -n --arg ak "${ALIBABA_CLOUD_ACCESS_KEY_ID}" --arg sk "${ALIBABA_CLOUD_ACCESS_KEY_SECRET}" \
    --arg st "${ALIBABA_CLOUD_SECURITY_TOKEN}" --arg region "${region}" \
    '{current: "sts", profiles: [{name: "sts", mode: "StsToken", access_key_id: $ak,
      access_key_secret: $sk, sts_token: $st, region_id: $region}]}' > "${cfg}" )
ali=(aliyun --profile sts --config-path "${cfg}")

# When the relay itself is unusable (down, agent offline, not logged in to ACR), fall back to
# copying straight from this runner, as before the relay: slow across the border on a bad day,
# but it can still finish. Needs ACR_DIRECT_DST_CREDS (user:password); skopeo must be installed.
# Not used when the relay ran and rejected the parameters or failed the copy itself: a direct
# copy would hit the same problem.
direct_copy() {
  local why="$1"
  if [[ -z "${ACR_DIRECT_DST_CREDS:-}" ]]; then
    echo "::error::relay unavailable (${why}), and no ACR_DIRECT_DST_CREDS for a direct copy"
    exit 1
  fi
  echo "::warning::relay unavailable (${why}); copying ${src} directly from the runner"
  local flags=(--all) src_auth=()
  [[ "${arch}" == amd64 ]] && flags=(--override-arch amd64 --override-os linux)
  [[ -n "${token}" ]] && src_auth=(--src-creds "x-access-token:${token}")
  # One long attempt: a killed upload restarts from zero, so retrying in short slices loses work.
  if timeout --signal=TERM 100m skopeo copy --retry-times 3 "${flags[@]}" "${src_auth[@]}" \
      --dest-creds "${ACR_DIRECT_DST_CREDS}" "docker://${src}" "docker://${dst}"; then
    echo "copied ${src} -> ${dst} (direct)"
    exit 0
  fi
  echo "::error::direct copy failed: ${src} -> ${dst}"
  exit 1
}

# The command is recreated (new id) whenever its script changes, so look it up by name.
command_id="$("${ali[@]}" ecs DescribeCommands --RegionId "${region}" --Name acr-relay-copy \
  | jq -r '.Commands.Command[0].CommandId // empty')" || command_id=""
if [[ -z "${command_id}" ]]; then
  direct_copy "command acr-relay-copy not found in ${region}"
fi

params="$(RELAY_SRC_TOKEN="${token}" jq -cn --arg src "${src}" --arg dst "${dst}" --arg arch "${arch}" \
  '{src: $src, dst: $dst, arch: $arch, src_token: env.RELAY_SRC_TOKEN}')"
invoke_id="$("${ali[@]}" ecs InvokeCommand --RegionId "${region}" --CommandId "${command_id}" \
  --InstanceId.1 "${instance}" --Parameters "${params}" | jq -r '.InvokeId // empty')" || invoke_id=""
unset params
if [[ -z "${invoke_id}" ]]; then
  direct_copy "could not invoke acr-relay-copy on ${instance}"
fi
echo "relay ${invoke_id}: ${src} -> ${dst} (${arch})"

# A cancelled job must not leave the relay writing into a release tag.
trap '"${ali[@]}" ecs StopInvocation --RegionId "${region}" --InvokeId "${invoke_id}" \
  --InstanceId.1 "${instance}" > /dev/null 2>&1 || true; rm -f "${cfg}"; exit 130' INT TERM

failures=0
while :; do
  if ! result="$("${ali[@]}" ecs DescribeInvocationResults --RegionId "${region}" \
      --InvokeId "${invoke_id}" --ContentEncoding PlainText)"; then
    failures=$((failures + 1))
    if (( failures >= 30 )); then
      echo "::error::lost track of relay invocation ${invoke_id} (DescribeInvocationResults kept failing)"
      exit 1
    fi
    sleep 10
    continue
  fi
  failures=0
  status="$(jq -r '.Invocation.InvocationResults.InvocationResult[0].InvocationStatus // empty' <<< "${result}")"
  case "${status}" in
    "" | Pending | Scheduled | Running | Stopping) sleep 10 ;;
    *) break ;;
  esac
done

# skopeo prints one "Copying blob" line per layer; keep the summary lines.
jq -r '.Invocation.InvocationResults.InvocationResult[0].Output // ""' <<< "${result}" \
  | grep -v '^Copying blob ' || true
exit_code="$(jq -r '.Invocation.InvocationResults.InvocationResult[0].ExitCode // 1' <<< "${result}")"
if [[ "${status}" == Success && "${exit_code}" == 0 ]]; then
  exit 0
fi
# Aborted / Invalid / Error: the command never ran (instance stopped, agent offline). Exit 3:
# the relay has no ACR login. Anything else (exit 2 rejected parameters, exit 1 failed copy,
# Timeout, Stopped) is not the relay being down.
case "${status}" in
  Aborted | Invalid | Error) direct_copy "invocation ${invoke_id} ${status}" ;;
esac
if [[ "${exit_code}" == 3 ]]; then
  direct_copy "relay has no ACR login"
fi
echo "::error::relay copy ${status} (exit ${exit_code}): ${src} -> ${dst}"
exit 1
