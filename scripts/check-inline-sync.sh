#!/usr/bin/env bash
# check-inline-sync.sh — verify inline bash in dependency-cooldown.yml
# matches scripts/*.sh byte-for-byte after the known normalization rules
# (YAML indent strip, function wrapper strip, shebang strip).
#
# Usage: ./scripts/check-inline-sync.sh
# Exit:  0 on success, 1 on any drift, missing sentinel, or residual
#        runtime checkout reference.

set -euo pipefail

WORKFLOW=".github/workflows/dependency-cooldown.yml"
SCRIPTS=(
  "scripts/extract-deps.sh"
  "scripts/check-release-age.sh"
)
YAML_INDENT="          "  # exactly 10 spaces — matches the `run: |` indent

fail=0

extract_inline_body() {
  local script_path="$1"
  local begin_marker="# --- BEGIN inline:${script_path} ---"
  local end_marker="# --- END inline:${script_path} ---"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    index($0, begin) { inside=1; next }
    index($0, end)   { inside=0; next }
    inside { print }
  ' "$WORKFLOW"
}

for script in "${SCRIPTS[@]}"; do
  if ! grep -qF "# --- BEGIN inline:${script} ---" "$WORKFLOW"; then
    echo "FAIL: no inline sentinel for '${script}' found in ${WORKFLOW}"
    fail=1
    continue
  fi

  # Strip first and last lines (the `fn() (` opener and the `)` closer),
  # then strip the 10-space YAML indent from every remaining line.
  inline_body=$(extract_inline_body "$script" | sed -E '1d;$d' | sed -E "s/^${YAML_INDENT}//")
  standalone_body=$(tail -n +2 "$script")

  if ! diff <(printf '%s\n' "$inline_body") <(printf '%s\n' "$standalone_body") > /dev/null 2>&1; then
    echo "FAIL: inline copy of '${script}' in ${WORKFLOW} does not match source:"
    diff <(printf '%s\n' "$inline_body") <(printf '%s\n' "$standalone_body") || true
    fail=1
  else
    echo "OK:   ${script} inline copy matches source"
  fi
done

# Safety net: residual runtime source-fetch references must not exist.
if grep -qF '${GITHUB_WORKSPACE}/shared-workflows/scripts/' "$WORKFLOW"; then
  echo "FAIL: residual runtime source-fetch reference in ${WORKFLOW}:"
  grep -nF '${GITHUB_WORKSPACE}/shared-workflows/scripts/' "$WORKFLOW" || true
  fail=1
fi

exit $fail
