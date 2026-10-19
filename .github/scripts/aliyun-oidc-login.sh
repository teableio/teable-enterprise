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
set -euo pipefail

: "${ALIYUN_ROLE_ARN:?}" "${ALIYUN_OIDC_PROVIDER_ARN:?}"

oidc_token="$(curl -fsS -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.aliyuncs.com" | jq -r '.value')"
test -n "${oidc_token}" && test "${oidc_token}" != null

# AssumeRoleWithOIDC needs no signature, but Timestamp is still a required
# common parameter.
resp="$(curl -fsS -X POST https://sts.aliyuncs.com/ \
  --data-urlencode "Action=AssumeRoleWithOIDC" \
  --data-urlencode "Version=2015-04-01" \
  --data-urlencode "Format=JSON" \
  --data-urlencode "Timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --data-urlencode "SignatureNonce=$(uuidgen)" \
  --data-urlencode "RoleArn=${ALIYUN_ROLE_ARN}" \
  --data-urlencode "OIDCProviderArn=${ALIYUN_OIDC_PROVIDER_ARN}" \
  --data-urlencode "OIDCToken=${oidc_token}" \
  --data-urlencode "RoleSessionName=github-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" \
  --data-urlencode "DurationSeconds=3600")"
ak="$(jq -r '.Credentials.AccessKeyId' <<<"${resp}")"
sk="$(jq -r '.Credentials.AccessKeySecret' <<<"${resp}")"
token="$(jq -r '.Credentials.SecurityToken' <<<"${resp}")"
test -n "${ak}" && test "${ak}" != null
echo "::add-mask::${sk}"
echo "::add-mask::${token}"
{
  echo "ALIBABA_CLOUD_ACCESS_KEY_ID=${ak}"
  echo "ALIBABA_CLOUD_ACCESS_KEY_SECRET=${sk}"
  echo "ALIBABA_CLOUD_SECURITY_TOKEN=${token}"
} >> "${GITHUB_ENV}"

# Release assets carry the version in their name (there is no "latest" asset).
if ! command -v aliyun >/dev/null 2>&1; then
  curl -fsSL https://github.com/aliyun/aliyun-cli/releases/download/v3.4.11/aliyun-cli-linux-3.4.11-amd64.tgz | tar -xz
  sudo mv aliyun /usr/local/bin/aliyun
fi
aliyun version
