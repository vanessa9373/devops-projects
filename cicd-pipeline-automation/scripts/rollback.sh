#!/usr/bin/env bash
# Roll an ECS service back to a prior task definition revision.
#
# Usage:
#   ./rollback.sh <task-def-family> <ecs-cluster> <ecs-service> [revision]
#
# If [revision] is omitted, rolls back to the revision immediately before
# the one currently running on the service (i.e. "undo the last deploy").
set -euo pipefail

FAMILY="${1:?task definition family is required}"
CLUSTER="${2:?ecs cluster is required}"
SERVICE="${3:?ecs service is required}"
TARGET_REVISION="${4:-}"

if [ -z "$TARGET_REVISION" ]; then
  echo "No revision given — looking up the currently running revision on $SERVICE..."
  CURRENT_TASK_DEF=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --query 'services[0].taskDefinition' \
    --output text)
  CURRENT_REVISION="${CURRENT_TASK_DEF##*:}"
  TARGET_REVISION=$((CURRENT_REVISION - 1))

  if [ "$TARGET_REVISION" -lt 1 ]; then
    echo "Error: current revision is $CURRENT_REVISION, no earlier revision exists." >&2
    exit 1
  fi
  echo "Currently running revision $CURRENT_REVISION — rolling back to $TARGET_REVISION."
fi

TARGET_TASK_DEF="${FAMILY}:${TARGET_REVISION}"

echo "Verifying $TARGET_TASK_DEF exists..."
aws ecs describe-task-definition --task-definition "$TARGET_TASK_DEF" >/dev/null

echo "Updating $SERVICE on $CLUSTER to $TARGET_TASK_DEF..."
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE" \
  --task-definition "$TARGET_TASK_DEF" \
  --force-new-deployment >/dev/null

echo "Waiting for the service to reach steady state on the rolled-back revision..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"

echo "Rollback complete: $SERVICE is now running $TARGET_TASK_DEF"
