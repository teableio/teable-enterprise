#!/usr/bin/env bash
# Writes a short-lived kubeconfig for the CN test cluster (teable-cn-test) and
# exports KUBECONFIG through GITHUB_ENV. Run aliyun-oidc-login.sh in an earlier step
# with ALIYUN_ROLE_ARN set to the cn-test deploy role.
#
# The context's default namespace is set to CN_TEST_NAMESPACE (teable-preview): the
# preview scripts in teable-ee (bootstrap admin, BYODB) call kubectl without -n.
# Inside the cluster the role only holds the teable-ci-deployer ClusterRole, bound per
# namespace (teable-infra: terraform/deployments/aliyun-ack-cn-test).
set -euo pipefail

: "${ALIBABA_CLOUD_ACCESS_KEY_ID:?run aliyun-oidc-login.sh first}"
: "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:?run aliyun-oidc-login.sh first}"
: "${ALIBABA_CLOUD_SECURITY_TOKEN:?run aliyun-oidc-login.sh first}"
cluster_id="${CN_TEST_CLUSTER_ID:-c6f4d3a3b2e064772aa3376c9680aab82}"
region="${CN_TEST_REGION:-cn-hangzhou}"
namespace="${CN_TEST_NAMESPACE:-teable-preview}"
kubeconfig="${RUNNER_TEMP}/cn-test-kubeconfig"

# The client certificate expires with the job instead of living for years.
aliyun cs DescribeClusterUserKubeconfig \
  --ClusterId "${cluster_id}" \
  --TemporaryDurationMinutes 120 \
  --mode StsToken \
  --access-key-id "${ALIBABA_CLOUD_ACCESS_KEY_ID}" \
  --access-key-secret "${ALIBABA_CLOUD_ACCESS_KEY_SECRET}" \
  --sts-token "${ALIBABA_CLOUD_SECURITY_TOKEN}" \
  --region "${region}" | jq -r '.config' >"${kubeconfig}"
test -s "${kubeconfig}"
chmod 600 "${kubeconfig}"
KUBECONFIG="${kubeconfig}" kubectl config set-context --current --namespace="${namespace}" >/dev/null
echo "KUBECONFIG=${kubeconfig}" >>"${GITHUB_ENV}"
# GITHUB_ENV only applies to later steps; prove access now.
KUBECONFIG="${kubeconfig}" kubectl get deployments --request-timeout=30s >/dev/null
echo "kubeconfig ready for ${cluster_id} (namespace ${namespace})"
