#!/usr/bin/env bash
# Wraps the terraform init/plan/apply cycle for one environment so
# "deploy dev" and "deploy prod" are the same command with a different
# argument, not two different runbooks to keep in sync by hand.
#
# Usage: ./deploy-environment.sh <dev|staging|prod> [--auto-approve]
set -euo pipefail

ENV="${1:?Usage: deploy-environment.sh <dev|staging|prod> [--auto-approve]}"
AUTO_APPROVE="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_DIR="$PROJECT_ROOT/terraform/environments/$ENV"

if [ ! -d "$ENV_DIR" ]; then
  echo "Error: no such environment '$ENV' (looked in $ENV_DIR)" >&2
  echo "Valid environments: dev, staging, prod" >&2
  exit 1
fi

echo "==> Deploying environment: $ENV"
cd "$ENV_DIR"

terraform init -input=false
terraform plan -out=tfplan

if [ "$AUTO_APPROVE" = "--auto-approve" ]; then
  terraform apply -auto-approve tfplan
else
  read -r -p "Apply this plan to '$ENV'? [y/N] " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    terraform apply tfplan
  else
    echo "Aborted — plan saved at $ENV_DIR/tfplan"
    exit 0
  fi
fi

rm -f tfplan
echo "==> $ENV apply complete"
terraform output
