#!/usr/bin/env bash
#
# tofu-check.sh — check whether OpenTofu (tofu) needs to run after a merge.
#
# This script is read-only. It NEVER runs `tofu apply`. It runs `tofu init`
# and `tofu plan`, then reports the plan and a preliminary safety verdict.
# The agent interprets the result and tells the user what to do.
#
# Usage:
#   tofu-check.sh <before-sha>
#
# Arguments:
#   before-sha  The git commit you were on before the merge. The script
#               compares it against HEAD to see whether tofu-managed files
#               changed.
#
# Exit codes:
#   0  tofu runs, or no tofu-managed files changed
#   3  tofu is not installed
#   4  tofu init failed
#
set -euo pipefail

BEFORE_SHA="${1:-}"
if [[ -z "$BEFORE_SHA" ]]; then
  echo "Usage: tofu-check.sh <before-sha>" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Which tofu-managed files changed between BEFORE_SHA and HEAD?
CHANGED="$(git diff --name-only "$BEFORE_SHA"..HEAD -- terraform \
  | grep -E '^terraform/.+\.(tf|tf\.json)$|^terraform/\.terraform\.lock\.hcl$' || true)"

if [[ -z "$CHANGED" ]]; then
  echo "OpenTofu: no tofu-managed files changed in these commits. No plan needed."
  exit 0
fi

echo "=== OpenTofu files changed ==="
printf '%s\n' "$CHANGED"

if ! command -v tofu >/dev/null 2>&1; then
  echo "ERROR: tofu is not installed on PATH."
  echo "Install OpenTofu, then run: tofu init && tofu plan"
  exit 3
fi

TF_DIR="$REPO_ROOT/terraform"
if [[ ! -d "$TF_DIR" ]]; then TF_DIR="$REPO_ROOT"; fi

echo "=== tofu version ==="
tofu version | head -1

echo "=== tofu init ==="
cd "$TF_DIR"
if tofu init -input=false >/tmp/tofu-init.log 2>&1; then
  echo "tofu init: OK"
else
  echo "tofu init: FAILED"
  sed -n '1,40p' /tmp/tofu-init.log
  exit 4
fi

echo "=== tofu plan (read-only) ==="
set +e
tofu plan -input=false -no-color >/tmp/tofu-plan.log 2>&1
plan_exit=$?
set -e

echo "--- plan summary ---"
grep -E '^Plan:' /tmp/tofu-plan.log || echo "(no Plan: line found)"

echo "--- resource changes ---"
grep -E '(will be updated in-place|will be created|will be destroyed|must be replaced|must be created|must be destroyed)' \
  /tmp/tofu-plan.log || echo "(no resource change found)"

echo "--- error lines ---"
grep -E '^Error:|^\s*Error:|invalid|401' /tmp/tofu-plan.log || echo "(none)"

echo "--- plan exit code: $plan_exit ---"

# Determine the safety verdict.
# If the plan printed a Plan: line, judge from that line.
# If the plan did not complete (for example a state-lock error or a missing
# credential), the verdict is UNKNOWN, not unsafe.
if grep -qE '^Plan:' /tmp/tofu-plan.log; then
  if grep -qE '^Plan: 0 to add, .* 0 to destroy' /tmp/tofu-plan.log \
     && ! grep -qE 'must be (replaced|destroyed)|1 to destroy|1 to add|to be destroyed' /tmp/tofu-plan.log; then
    echo "PLAN_SAFE=true"
  else
    echo "PLAN_SAFE=false"
  fi
else
  echo "PLAN_UNKNOWN=true"
  echo "Reason: the plan did not complete. Read the error lines above."
fi

# Report lockfile changes that init may have made.
echo "=== lockfile changes from init ==="
git -C "$REPO_ROOT" diff --stat -- terraform/.terraform.lock.hcl || echo "(none)"
