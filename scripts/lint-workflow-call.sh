#!/usr/bin/env bash
# lint-workflow-call.sh — fail CI if any workflow_call file uses
# caller-scoped context variables as checkout refs.
#
# Forbidden patterns (see issue #29, #30):
#   ref: ${{ github.workflow_sha }}
#   ref: ${{ github.sha }}
#   ref: ${{ github.ref }}
#
# These resolve to the *caller's* context in a reusable workflow,
# not the workflow's own commit — causing deterministic failures
# on every cross-repo consumer.
#
# Usage: ./scripts/lint-workflow-call.sh [root-dir]
#   root-dir defaults to "." (repo root).
# Exit: 0 if clean, 1 if any violation found.

set -euo pipefail

ROOT="${1:-.}"
WORKFLOWS_DIR="$ROOT/.github/workflows"

if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "No .github/workflows/ directory found — nothing to lint."
  exit 0
fi

FORBIDDEN='ref:.*\$\{\{[[:space:]]*github\.(workflow_sha|sha|ref)[[:space:]]*\}\}'

fail=0

for file in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  [ -f "$file" ] || continue

  # Only lint reusable workflow files (those with workflow_call trigger)
  if ! grep -qE '^[[:space:]]*workflow_call:' "$file"; then
    continue
  fi

  # Check for forbidden caller-context ref patterns
  if matches=$(grep -nE "$FORBIDDEN" "$file"); then
    echo "FAIL: $file contains caller-context ref(s) forbidden in workflow_call files:"
    echo "$matches"
    echo ""
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "OK: no caller-context refs found in workflow_call files."
fi

exit $fail
