#!/usr/bin/env bash
# check-inline-sync.sh — verify inline bash in workflow YAMLs matches
# scripts/*.sh byte-for-byte after the known normalization rules
# (YAML indent strip, function wrapper strip, shebang strip).
#
# Usage: ./scripts/check-inline-sync.sh
# Exit:  0 on success, 1 on any drift, missing sentinel, or residual
#        runtime checkout reference.

set -euo pipefail

# Each entry: "<workflow-yaml>:<script-path>"
INLINE_PAIRS=(
  ".github/workflows/dependency-cooldown.yml:scripts/extract-deps.sh"
  ".github/workflows/dependency-cooldown.yml:scripts/check-release-age.sh"
  ".github/workflows/dependency-cooldown.yml:scripts/diff-touches-lockfile.sh"
  ".github/workflows/dependency-cooldown.yml:scripts/pr-body-to-deps.sh"
  ".github/workflows/tag-release.yml:scripts/bump-version-files.sh"
)

YAML_INDENT="          "  # exactly 10 spaces — matches the `run: |` indent

fail=0

extract_inline_body() {
  local workflow="$1" script_path="$2"
  local begin_marker="# --- BEGIN inline:${script_path} ---"
  local end_marker="# --- END inline:${script_path} ---"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    index($0, begin) { inside=1; next }
    index($0, end)   { inside=0; next }
    inside { print }
  ' "$workflow"
}

for pair in "${INLINE_PAIRS[@]}"; do
  workflow="${pair%%:*}"
  script="${pair##*:}"

  if ! grep -qF "# --- BEGIN inline:${script} ---" "$workflow"; then
    echo "FAIL: no inline sentinel for '${script}' found in ${workflow}"
    fail=1
    continue
  fi

  # Strip first and last lines (the `fn() (` opener and the `)` closer),
  # then strip the 10-space YAML indent from every remaining line.
  inline_body=$(extract_inline_body "$workflow" "$script" | sed -E '1d;$d' | sed -E "s/^${YAML_INDENT}//")
  standalone_body=$(tail -n +2 "$script")

  if ! diff <(printf '%s\n' "$inline_body") <(printf '%s\n' "$standalone_body") > /dev/null 2>&1; then
    echo "FAIL: inline copy of '${script}' in ${workflow} does not match source:"
    diff <(printf '%s\n' "$inline_body") <(printf '%s\n' "$standalone_body") || true
    fail=1
  else
    echo "OK:   ${script} inline copy matches source ($workflow)"
  fi
done

# Safety net: residual runtime source-fetch references must not exist in any tracked workflow.
for workflow in .github/workflows/*.yml; do
  if grep -qF '${GITHUB_WORKSPACE}/shared-workflows/scripts/' "$workflow"; then
    echo "FAIL: residual runtime source-fetch reference in ${workflow}:"
    grep -nF '${GITHUB_WORKSPACE}/shared-workflows/scripts/' "$workflow" || true
    fail=1
  fi
done

exit $fail
