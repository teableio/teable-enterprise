#!/usr/bin/env bash
# Writes a short-lived kubeconfig for the CN test cluster (teable-cn-test) and
# exports KUBECONFIG through GITHUB_ENV. Run aliyun-oidc-login.sh in an earlier step
# with ALIYUN_ROLE_ARN set to the cn-test deploy role.
#
# The API server only has a private endpoint, so this goes through the Hangzhou machine
# bastion (teable-bastion-cn-k8s) with aliyun-kube-tunnel.sh: private-endpoint kubeconfig
# with a 2-hour certificate, plus a Session Manager port forward that stays up for the
# rest of the job (later steps reach the cluster at 127.0.0.1:<port>).
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
bastion="${CN_TEST_BASTION:-i-bp11l83r5m3vqmbimu1o}"
region="${CN_TEST_REGION:-cn-hangzhou}"
namespace="${CN_TEST_NAMESPACE:-teable-preview}"
port="${CN_TEST_TUNNEL_PORT:-16645}"
kubeconfig="${RUNNER_TEMP}/cn-test-kubeconfig"

bash "$(dirname "$0")/aliyun-kube-tunnel.sh" "${cluster_id}" "${bastion}" "${region}" "${kubeconfig}" "${port}"
KUBECONFIG="${kubeconfig}" kubectl config set-context --current --namespace="${namespace}" >/dev/null
echo "KUBECONFIG=${kubeconfig}" >>"${GITHUB_ENV}"
# GITHUB_ENV only applies to later steps; prove namespace access now.
KUBECONFIG="${kubeconfig}" kubectl get deployments --request-timeout=30s >/dev/null
echo "kubeconfig ready for ${cluster_id} (namespace ${namespace}, via bastion ${bastion})"
