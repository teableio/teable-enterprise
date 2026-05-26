#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local key="$1"
  if [ -z "${!key:-}" ]; then
    echo "::error::Missing required env ${key}"
    exit 1
  fi
}

if [ -z "${KUBE_NAMESPACE:-}" ] && [ -n "${NAMESPACE:-}" ]; then
  KUBE_NAMESPACE="ns-${NAMESPACE}"
fi

require_env APP_DEPLOYMENT

WORKER_DEPLOYMENT="${WORKER_DEPLOYMENT:-${APP_DEPLOYMENT}-byodb-migration-worker}"
WORKER_CONTAINER="${WORKER_CONTAINER:-byodb-migration-worker}"
WORKER_ARG="${WORKER_ARG:-byodb-migration-worker-skip-migrate}"
WORKER_REPLICAS="${WORKER_REPLICAS:-1}"
WORKER_TERMINATION_GRACE_SECONDS="${WORKER_TERMINATION_GRACE_SECONDS:-30}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if [ -n "${KUBE_CONFIG:-}" ]; then
  mkdir -p ~/.kube
  echo "${KUBE_CONFIG}" | base64 -d > ~/.kube/config
fi

kubectl_namespace_args=()
if [ -n "${KUBE_NAMESPACE:-}" ]; then
  kubectl_namespace_args=(-n "${KUBE_NAMESPACE}")
fi

kubectl "${kubectl_namespace_args[@]}" get deployment "${APP_DEPLOYMENT}" -o json > "${tmp_dir}/app.json"

APP_CONTAINER="${APP_CONTAINER:-}"
if [ -z "${APP_CONTAINER}" ]; then
  APP_CONTAINER="$(jq -r '.spec.template.spec.containers[0].name' "${tmp_dir}/app.json")"
fi

if ! jq -e --arg container "${APP_CONTAINER}" \
  '.spec.template.spec.containers[] | select(.name == $container)' \
  "${tmp_dir}/app.json" >/dev/null; then
  echo "::error::Container ${APP_CONTAINER} was not found in deployment ${APP_DEPLOYMENT}"
  exit 1
fi

WORKER_IMAGE="${WORKER_IMAGE:-}"
if [ -z "${WORKER_IMAGE}" ]; then
  WORKER_IMAGE="$(jq -r --arg container "${APP_CONTAINER}" \
    '.spec.template.spec.containers[] | select(.name == $container) | .image' \
    "${tmp_dir}/app.json")"
fi

WORKER_OTEL_SERVICE_NAME="${WORKER_OTEL_SERVICE_NAME:-${WORKER_DEPLOYMENT}}"

jq \
  --arg appContainer "${APP_CONTAINER}" \
  --arg workerDeployment "${WORKER_DEPLOYMENT}" \
  --arg workerContainer "${WORKER_CONTAINER}" \
  --arg workerImage "${WORKER_IMAGE}" \
  --arg workerArg "${WORKER_ARG}" \
  --arg workerReplicas "${WORKER_REPLICAS}" \
  --arg terminationGraceSeconds "${WORKER_TERMINATION_GRACE_SECONDS}" \
  --arg otelServiceName "${WORKER_OTEL_SERVICE_NAME}" \
  '
  def worker_env:
    [
      {
        name: "BYODB_SPACE_DATA_DB_MIGRATION_WORKER_ID",
        valueFrom: { fieldRef: { fieldPath: "metadata.name" } }
      }
    ] + if $otelServiceName == "" then [] else [{ name: "OTEL_SERVICE_NAME", value: $otelServiceName }] end;

  def without_worker_env:
    map(select(.name != "BYODB_SPACE_DATA_DB_MIGRATION_WORKER_ID" and .name != "OTEL_SERVICE_NAME"));

  def non_root_id($value):
    if ($value // 0) == 0 then 1001 else $value end;

  def worker_security_context:
    (.securityContext // {}) as $securityContext
    | $securityContext + {
        allowPrivilegeEscalation: false,
        privileged: false,
        runAsNonRoot: true,
        runAsUser: non_root_id($securityContext.runAsUser),
        runAsGroup: non_root_id($securityContext.runAsGroup),
        seccompProfile: (($securityContext.seccompProfile // {}) + { type: "RuntimeDefault" }),
        capabilities: ((($securityContext.capabilities // {}) | del(.add)) + {
          drop: ((($securityContext.capabilities.drop // []) + ["ALL"]) | unique)
        })
      };

  (.spec.template.spec.containers[] | select(.name == $appContainer)) as $appContainerSpec
  | {
      apiVersion: "apps/v1",
      kind: "Deployment",
      metadata: {
        name: $workerDeployment,
        namespace: .metadata.namespace,
        labels: ((.metadata.labels // {}) + {
          app: $workerDeployment,
          "app.kubernetes.io/component": "byodb-migration-worker"
        }),
        annotations: ((.metadata.annotations // {}) + {
          originImageName: $workerImage
        })
      },
      spec: {
        replicas: ($workerReplicas | tonumber),
        revisionHistoryLimit: (.spec.revisionHistoryLimit // 1),
        minReadySeconds: (.spec.minReadySeconds // 0),
        selector: {
          matchLabels: {
            app: $workerDeployment
          }
        },
        template: {
          metadata: {
            labels: ((.spec.template.metadata.labels // {}) + {
              app: $workerDeployment,
              "app.kubernetes.io/component": "byodb-migration-worker"
            }),
            annotations: (.spec.template.metadata.annotations // {})
          },
          spec: (
            .spec.template.spec
            | del(.containers, .initContainers)
            | .terminationGracePeriodSeconds = ($terminationGraceSeconds | tonumber)
            | .containers = [
                (
                  $appContainerSpec
                  | .name = $workerContainer
                  | .image = $workerImage
                  | .args = [$workerArg]
                  | del(.command, .ports, .livenessProbe, .readinessProbe, .startupProbe, .lifecycle)
                  | .env = (((.env // []) | without_worker_env) + worker_env)
                  | .securityContext = worker_security_context
                )
              ]
          )
        }
      }
    }
  ' "${tmp_dir}/app.json" > "${tmp_dir}/byodb-migration-worker.json"

kubectl "${kubectl_namespace_args[@]}" apply -f "${tmp_dir}/byodb-migration-worker.json"
kubectl "${kubectl_namespace_args[@]}" rollout status "deployment/${WORKER_DEPLOYMENT}" --timeout="${ROLLOUT_TIMEOUT}"
