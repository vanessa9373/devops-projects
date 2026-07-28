#!/usr/bin/env bash
# One-time local setup check — confirms the tools and AWS credentials this
# project needs are actually in place before anyone runs terraform for real.
set -euo pipefail

MISSING=0

check() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "  [ok] $1 ($(command -v "$1"))"
  else
    echo "  [MISSING] $1 — $2"
    MISSING=1
  fi
}

echo "Checking required tools..."
check terraform "https://developer.hashicorp.com/terraform/install"
check aws "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"

echo ""
echo "Checking AWS credentials..."
if aws sts get-caller-identity >/dev/null 2>&1; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  echo "  [ok] Authenticated to AWS account $ACCOUNT"
else
  echo "  [MISSING] No valid AWS credentials (aws sts get-caller-identity failed)"
  MISSING=1
fi

echo ""
if [ "$MISSING" -eq 0 ]; then
  echo "Everything's in place. Next: ./scripts/deploy-environment.sh dev"
else
  echo "Fix the items above before running deploy-environment.sh."
  exit 1
fi
