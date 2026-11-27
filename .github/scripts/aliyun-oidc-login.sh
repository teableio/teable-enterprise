#!/usr/bin/env bash
# Exchange the job's GitHub OIDC token for 1h Aliyun STS credentials
# (AssumeRoleWithOIDC, no long-lived keys) and install the pinned aliyun CLI.
#
# Requires `permissions: id-token: write` on the job (and on the caller job
# when this runs inside a reusable workflow). The RAM role trusts
# repo:teableio/teable-enterprise:ref:refs/heads/main only, so runs from any
# other ref fail at AssumeRoleWithOIDC.
#
# Inputs (env): ALIYUN_ROLE_ARN, ALIYUN_OIDC_PROVIDER_ARN
# Outputs (GITHUB_ENV): ALIBABA_CLOUD_ACCESS_KEY_ID / _SECRET / _SECURITY_TOKEN
#
# Every network call retries transient failures (connection errors, timeouts,
# HTTP 408 / 429 / 5xx). A single GitHub 504 on the CLI download once stopped a
# whole stable release; any other HTTP error still fails at once.
set -euo pipefail

: "${ALIYUN_ROLE_ARN:?}" "${ALIYUN_OIDC_PROVIDER_ARN:?}"

ALIYUN_CLI_VERSION=3.4.11
# From the release's SHASUMS256.txt.
ALIYUN_CLI_SHA256=a7e3df497db14c10d4d7587795e9fa7849b0c51dfce02908b9de5a41fe717d5c
STS_ATTEMPTS=4

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch_oidc_token() {
  curl -fsS --retry 4 --retry-connrefused --connect-timeout 20 --max-time 30 \
    -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.aliyuncs.com" | jq -r '.value'
}

# Writes the response body to $1 and prints the HTTP status (000 when no
# answer came back). AssumeRoleWithOIDC needs no signature, but Timestamp and
# SignatureNonce are still required common parameters; both are new on every
# attempt, so a retry is never refused as a replay.
assume_role() {
  curl -sS -o "$1" -w '%{http_code}' --connect-timeout 20 --max-time 60 \
    -X POST https://sts.aliyuncs.com/ \
    --data-urlencode "Action=AssumeRoleWithOIDC" \
    --data-urlencode "Version=2015-04-01" \
    --data-urlencode "Format=JSON" \
    --data-urlencode "Timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --data-urlencode "SignatureNonce=$(uuidgen)" \
    --data-urlencode "RoleArn=${ALIYUN_ROLE_ARN}" \
    --data-urlencode "OIDCProviderArn=${ALIYUN_OIDC_PROVIDER_ARN}" \
    --data-urlencode "OIDCToken=$2" \
    --data-urlencode "RoleSessionName=github-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" \
    --data-urlencode "DurationSeconds=3600"
}

sts_body="${work}/sts.json"
for attempt in $(seq 1 "${STS_ATTEMPTS}"); do
  # A fresh OIDC token per attempt: the retries can outlast the first one.
  oidc_token="$(fetch_oidc_token)"
  # `test a && test b` would not stop the script under set -e when `a` fails.
  if [ -z "${oidc_token}" ] || [ "${oidc_token}" = null ]; then
    echo "::error::the GitHub OIDC token request returned no token" >&2
    exit 1
  fi
  code="$(assume_role "${sts_body}" "${oidc_token}")" || code=000
  case "${code}" in
    2??) break ;;
    000 | 408 | 429 | 5??)
      if [ "${attempt}" -lt "${STS_ATTEMPTS}" ]; then
        echo "AssumeRoleWithOIDC: HTTP ${code}, retrying (${attempt}/${STS_ATTEMPTS})" >&2
        sleep $((attempt * 5))
        continue
      fi
      ;;
  esac
  # A failed call carries no credentials, so its body is safe to show.
  echo "::error::AssumeRoleWithOIDC failed with HTTP ${code}: $(head -c 500 "${sts_body}" 2>/dev/null)" >&2
  exit 1
done
resp="$(cat "${sts_body}")"
rm -f "${sts_body}"
ak="$(jq -r '.Credentials.AccessKeyId' <<<"${resp}")"
sk="$(jq -r '.Credentials.AccessKeySecret' <<<"${resp}")"
token="$(jq -r '.Credentials.SecurityToken' <<<"${resp}")"
if [ -z "${ak}" ] || [ "${ak}" = null ]; then
  echo "::error::AssumeRoleWithOIDC answered without credentials" >&2
  exit 1
fi
echo "::add-mask::${sk}"
echo "::add-mask::${token}"
{
  echo "ALIBABA_CLOUD_ACCESS_KEY_ID=${ak}"
  echo "ALIBABA_CLOUD_ACCESS_KEY_SECRET=${sk}"
  echo "ALIBABA_CLOUD_SECURITY_TOKEN=${token}"
} >> "${GITHUB_ENV}"

# Release assets carry the version in their name (there is no "latest" asset).
# Downloaded to a file rather than piped into tar: a retried transfer must not
# feed a half-written stream to tar, and the checksum covers the whole archive.
if ! command -v aliyun >/dev/null 2>&1; then
  curl -fsSL --retry 5 --retry-connrefused --connect-timeout 30 --max-time 300 \
    -o "${work}/aliyun-cli.tgz" \
    "https://github.com/aliyun/aliyun-cli/releases/download/v${ALIYUN_CLI_VERSION}/aliyun-cli-linux-${ALIYUN_CLI_VERSION}-amd64.tgz"
  echo "${ALIYUN_CLI_SHA256}  ${work}/aliyun-cli.tgz" | sha256sum -c --quiet -
  tar -xzf "${work}/aliyun-cli.tgz" -C "${work}" aliyun
  sudo install -m 0755 "${work}/aliyun" /usr/local/bin/aliyun
fi
aliyun version
