#!/usr/bin/env bash
# The "testing technique" this project actually uses: fmt + validate across
# every module and every environment, in one command. Run locally before a
# commit, and again in CI (.github/workflows/terraform-ci.yml) on every PR —
# same script, so "it passed CI" and "it passed on my machine" mean the
# same thing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(dirname "$SCRIPT_DIR")/terraform"

FAILED=0

check_dir() {
  local dir="$1"
  local out
  out="$(mktemp)"
  echo "==> $dir"

  if ! terraform -chdir="$dir" fmt -check -diff >"$out" 2>&1; then
    echo "    fmt: FAILED"
    cat "$out"
    FAILED=1
  else
    echo "    fmt: ok"
  fi

  terraform -chdir="$dir" init -backend=false -input=false >/dev/null 2>&1

  if terraform -chdir="$dir" validate >"$out" 2>&1; then
    echo "    validate: ok"
  else
    echo "    validate: FAILED"
    cat "$out"
    FAILED=1
  fi

  rm -f "$out"
  rm -rf "$dir/.terraform" "$dir/.terraform.lock.hcl"
}

for module_dir in "$TERRAFORM_DIR"/modules/*/; do
  check_dir "${module_dir%/}"
done

for env_dir in "$TERRAFORM_DIR"/environments/*/; do
  check_dir "${env_dir%/}"
done

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "All modules and environments passed fmt + validate."
else
  echo "One or more checks failed — see output above."
  exit 1
fi
