#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local key="$1"
  if [ -z "${!key:-}" ]; then
    echo "::error::Missing required env ${key}"
    exit 1
  fi
}

require_env ECS_CLUSTER
require_env APP_SERVICE
require_env APP_TASK_DEFINITION_FILE

AWS_REGION="${AWS_REGION:-us-west-2}"
APP_CONTAINER="${APP_CONTAINER:-teable}"
WORKER_TASK_FAMILY="${WORKER_TASK_FAMILY:-teable-byodb-migration-worker}"
WORKER_SERVICE="${WORKER_SERVICE:-teable-byodb-migration-worker}"
WORKER_CONTAINER="${WORKER_CONTAINER:-teable}"
WORKER_COMMAND="${WORKER_COMMAND:-byodb-migration-worker-skip-migrate}"
WORKER_DESIRED_COUNT="${WORKER_DESIRED_COUNT:-1}"
WORKER_OTEL_SERVICE_NAME="${WORKER_OTEL_SERVICE_NAME:-${WORKER_SERVICE}}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

aws ecs describe-services \
  --cluster "${ECS_CLUSTER}" \
  --services "${APP_SERVICE}" \
  --include TAGS \
  --region "${AWS_REGION}" \
  --query 'services[0]' > "${tmp_dir}/app-service.json"

if ! jq -e '.serviceName != null' "${tmp_dir}/app-service.json" >/dev/null; then
  echo "::error::ECS service ${APP_SERVICE} was not found in cluster ${ECS_CLUSTER}"
  exit 1
fi

if ! jq -e --arg appContainer "${APP_CONTAINER}" \
  '.containerDefinitions[] | select(.name == $appContainer)' \
  "${APP_TASK_DEFINITION_FILE}" >/dev/null; then
  echo "::error::Container ${APP_CONTAINER} was not found in task definition ${APP_TASK_DEFINITION_FILE}"
  exit 1
fi

APP_TASK_CPU="$(jq -r '.cpu // empty' "${APP_TASK_DEFINITION_FILE}")"
APP_TASK_MEMORY="$(jq -r '.memory // empty' "${APP_TASK_DEFINITION_FILE}")"
WORKER_TASK_CPU="${WORKER_TASK_CPU:-${APP_TASK_CPU}}"
WORKER_TASK_MEMORY="${WORKER_TASK_MEMORY:-${APP_TASK_MEMORY}}"

jq \
  --arg appContainer "${APP_CONTAINER}" \
  --arg workerTaskFamily "${WORKER_TASK_FAMILY}" \
  --arg workerContainer "${WORKER_CONTAINER}" \
  --arg workerCommand "${WORKER_COMMAND}" \
  --arg workerCpu "${WORKER_TASK_CPU}" \
  --arg workerMemory "${WORKER_TASK_MEMORY}" \
  --arg workerId "${WORKER_SERVICE}" \
  --arg otelServiceName "${WORKER_OTEL_SERVICE_NAME}" \
  '
  def registration_fields:
    {
      family,
      taskRoleArn,
      executionRoleArn,
      networkMode,
      containerDefinitions,
      volumes,
      placementConstraints,
      requiresCompatibilities,
      cpu,
      memory,
      runtimePlatform,
      ephemeralStorage,
      proxyConfiguration,
      inferenceAccelerators,
      ipcMode,
      pidMode
    }
    | with_entries(select(.value != null and .value != []));

  def upsert_env($name; $value):
    map(select(.name != $name)) + [{ name: $name, value: $value }];

  (.containerDefinitions[] | select(.name == $appContainer)) as $appContainerSpec
  | registration_fields
  | .family = $workerTaskFamily
  | .cpu = $workerCpu
  | .memory = $workerMemory
  | .containerDefinitions = [
      (
        $appContainerSpec
        | .name = $workerContainer
        | .command = [$workerCommand]
        | del(.portMappings, .healthCheck, .dependsOn)
        | .environment = (
            ((.environment // [])
              | upsert_env("BYODB_SPACE_DATA_DB_MIGRATION_WORKER_ID"; $workerId)
              | upsert_env("OTEL_SERVICE_NAME"; $otelServiceName))
          )
      )
    ]
  ' "${APP_TASK_DEFINITION_FILE}" > "${tmp_dir}/worker-task-definition.json"

TASK_DEFINITION_ARN="$(aws ecs register-task-definition \
  --cli-input-json "file://${tmp_dir}/worker-task-definition.json" \
  --region "${AWS_REGION}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text)"

echo "Registered BYODB migration worker task definition: ${TASK_DEFINITION_ARN}"

aws ecs describe-services \
  --cluster "${ECS_CLUSTER}" \
  --services "${WORKER_SERVICE}" \
  --region "${AWS_REGION}" \
  --query 'services[0]' > "${tmp_dir}/worker-service.json"

if jq -e '.serviceName != null and .status != "INACTIVE"' "${tmp_dir}/worker-service.json" >/dev/null; then
  echo "Updating existing BYODB migration worker ECS service: ${WORKER_SERVICE}"
  aws ecs update-service \
    --cluster "${ECS_CLUSTER}" \
    --service "${WORKER_SERVICE}" \
    --task-definition "${TASK_DEFINITION_ARN}" \
    --desired-count "${WORKER_DESIRED_COUNT}" \
    --force-new-deployment \
    --region "${AWS_REGION}" >/dev/null
else
  echo "Creating BYODB migration worker ECS service: ${WORKER_SERVICE}"
  jq \
    --arg cluster "${ECS_CLUSTER}" \
    --arg serviceName "${WORKER_SERVICE}" \
    --arg taskDefinition "${TASK_DEFINITION_ARN}" \
    --arg desiredCount "${WORKER_DESIRED_COUNT}" \
    '
    {
      cluster: $cluster,
      serviceName: $serviceName,
      taskDefinition: $taskDefinition,
      desiredCount: ($desiredCount | tonumber),
      networkConfiguration,
      platformVersion,
      enableExecuteCommand,
      enableECSManagedTags,
      propagateTags
    }
    + if (.capacityProviderStrategy // []) != [] then
        { capacityProviderStrategy }
      else
        { launchType: (.launchType // "FARGATE") }
      end
    | with_entries(select(.value != null and .value != []))
    ' "${tmp_dir}/app-service.json" > "${tmp_dir}/create-worker-service.json"

  aws ecs create-service \
    --cli-input-json "file://${tmp_dir}/create-worker-service.json" \
    --region "${AWS_REGION}" >/dev/null
fi

aws ecs wait services-stable \
  --cluster "${ECS_CLUSTER}" \
  --services "${WORKER_SERVICE}" \
  --region "${AWS_REGION}"

echo "BYODB migration worker ECS service is stable: ${WORKER_SERVICE}"
