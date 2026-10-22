#!/usr/bin/env bash
# Reach an Aliyun ACK cluster whose API server has only a private endpoint, through a bastion.
#
#   .github/scripts/aliyun-kube-tunnel.sh <cluster-id> <bastion-instance-id> <region> <kubeconfig-out> [local-port]
#
# 1. fetch the cluster's private-endpoint kubeconfig;
# 2. start a Cloud Assistant Session Manager port forward (bastion -> API server) in the background;
#    it keeps running for the rest of the job;
# 3. point the kubeconfig at the local port (the certificate is checked against "kubernetes").
#
# Credentials: ALIBABA_CLOUD_ACCESS_KEY_ID / _SECRET / _SECURITY_TOKEN from aliyun-oidc-login.sh.
# The role needs cs:DescribeClusterUserKubeconfig on the cluster and ecs:StartTerminalSession on the
# bastion (teableio/teable-infra: terraform/deployments/aliyun-bastion).
set -euo pipefail

cluster="${1:?usage: aliyun-kube-tunnel.sh <cluster-id> <bastion> <region> <kubeconfig-out> [local-port]}"
bastion="${2:?}"
region="${3:?}"
out="${4:?}"
port="${5:-16644}"
: "${ALIBABA_CLOUD_ACCESS_KEY_ID:?}" "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:?}" "${ALIBABA_CLOUD_SECURITY_TOKEN:?}"

# Credentials go into a private aliyun CLI config file shared by both tools, never onto a command
# line (process arguments are visible to anyone on the runner).
cfg="${out}.aliyun.json"
( umask 077
  jq -n --arg ak "${ALIBABA_CLOUD_ACCESS_KEY_ID}" --arg sk "${ALIBABA_CLOUD_ACCESS_KEY_SECRET}" \
    --arg st "${ALIBABA_CLOUD_SECURITY_TOKEN}" --arg region "${region}" \
    '{current: "sts", profiles: [{name: "sts", mode: "StsToken", access_key_id: $ak,
      access_key_secret: $sk, sts_token: $st, region_id: $region}]}' > "${cfg}" )
auth=(--profile sts --config-path "${cfg}")

# The download URL carries no version, so pin the checksum: an upstream change fails here loudly.
cli="${RUNNER_TEMP:-/tmp}/ali-instance-cli"
curl -fsSL -o "${cli}" https://aliyun-client-assist.oss-accelerate.aliyuncs.com/session-manager/linux/ali-instance-cli
echo "b3fda8ee05f6dbd8fc6016e873e92c932212e5b8f6cd6c30fe51b23f6c179521  ${cli}" | sha256sum -c -
chmod +x "${cli}"

aliyun cs GET "/k8s/${cluster}/user_config" --PrivateIpAddress true --region "${region}" "${auth[@]}" \
  | jq -r '.config' > "${out}"
chmod 600 "${out}"
endpoint="$(KUBECONFIG="${out}" kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
endpoint="${endpoint#https://}"
test -n "${endpoint}"

log="${out}.tunnel.log"
nohup "${cli}" portforward -i "${bastion}" -r "${endpoint}" -l "${port}" --region "${region}" "${auth[@]}" \
  > "${log}" 2>&1 &
echo $! > "${out}.tunnel.pid"
for _ in $(seq 1 30); do
  grep -q "Waiting for connections" "${log}" && break
  if ! kill -0 "$(cat "${out}.tunnel.pid")" 2>/dev/null; then cat "${log}" >&2; exit 1; fi
  sleep 1
done
grep -q "Waiting for connections" "${log}" || { cat "${log}" >&2; exit 1; }

KUBECONFIG="${out}" kubectl config set-cluster "$(KUBECONFIG="${out}" kubectl config view -o jsonpath='{.clusters[0].name}')" \
  --server="https://127.0.0.1:${port}" --tls-server-name=kubernetes >/dev/null
KUBECONFIG="${out}" kubectl version --request-timeout=30s >/dev/null
echo "tunnel ready: KUBECONFIG=${out}"
