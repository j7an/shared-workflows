#!/usr/bin/env bats
# safety-workflow-contract.bats — static assertions that the public
# workflow_call surface of dependency-safety.yml matches the v4 contract
# (issue #85): release_age_policy default "off", auto_merge default true,
# minimum_release_age_days default 5, fail_on_age_violation removed.
#
# Why: safety-verdict.bats proves the verdict logic; it does not prove the
# reusable workflow's declared inputs satisfy the documented contract.

YAML=".github/workflows/dependency-safety.yml"

# input_default <input-name> — print the `default:` value declared for an
# input in the workflow_call inputs block (input names at 6-space indent,
# properties at 8-space indent).
input_default() {
  awk -v key="      $1:" '
    $0 == key { found=1; next }
    found && /^        default:/ { sub(/^        default: */, ""); print; exit }
    found && /^      [a-z_]+:$/ { exit }
  ' "$YAML"
}

@test "dependency-safety.yml: auto_merge defaults to true" {
  [ "$(input_default auto_merge)" = "true" ]
}

@test "dependency-safety.yml: release_age_policy is a string input with quoted default \"off\"" {
  grep -q '^      release_age_policy:$' "$YAML"
  awk '/^      release_age_policy:$/{f=1;next} f&&/^      [a-z_]+:$/{exit} f' "$YAML" | grep -q 'type: string'
  [ "$(input_default release_age_policy)" = '"off"' ]
}

@test "dependency-safety.yml: minimum_release_age_days defaults to 5" {
  [ "$(input_default minimum_release_age_days)" = "5" ]
}

@test "dependency-safety.yml: fail_on_age_violation is fully removed" {
  count=$(grep -ci 'fail_on_age_violation' "$YAML" || true)
  [ "$count" -eq 0 ]
}

@test "dependency-safety.yml: RELEASE_AGE_POLICY env is wired from inputs" {
  grep -qF 'RELEASE_AGE_POLICY: ${{ inputs.release_age_policy }}' "$YAML"
}

@test "dependency-safety embeds npm-bump-extract" {
  run grep -c "BEGIN inline:scripts/npm-bump-extract.sh" .github/workflows/dependency-safety.yml
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "dependency-safety invokes all three npm-bump-extract modes" {
  for mode in deps lockfile-entries cleared-paths; do
    run grep -q "npm_bump_extract --mode=$mode" .github/workflows/dependency-safety.yml
    [ "$status" -eq 0 ]
  done
}

@test "npm tier-1 loop queries the NPM GHSA ecosystem" {
  run grep -q "ecosystem: NPM" .github/workflows/dependency-safety.yml
  [ "$status" -eq 0 ]
}

@test "tier-2 sweep uses the OSV batch endpoint" {
  run grep -q "api.osv.dev/v1/querybatch" .github/workflows/dependency-safety.yml
  [ "$status" -eq 0 ]
}

@test "npm release age uses deps.dev stable v3, not v3alpha" {
  run grep -q "api.deps.dev/v3/systems/npm" .github/workflows/dependency-safety.yml
  [ "$status" -eq 0 ]
  run grep -q "v3alpha" .github/workflows/dependency-safety.yml
  [ "$status" -ne 0 ]
}

@test "PR-comment age headers are composed, not hardcoded to 'younger than'" {
  run grep -c 'RESULTS_HEADER="$(age_status_phrase)' .github/workflows/dependency-safety.yml
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "no RESULTS_HEADER still claims every age failure is too young" {
  # grep -c exits 1 on zero matches, so assert on output, not status.
  run grep -c 'RESULTS_HEADER="${AGE_VIOLATION_COUNT}' .github/workflows/dependency-safety.yml
  [ "$output" -eq 0 ]
}

# extract_comment_body_printf — isolate the primary COMMENT_BODY assembly (the
# multi-section PR comment), not the unrelated fallback COMMENT_BODY further
# down in the same step. Anchored on the literal format string so it survives
# unrelated line-number drift elsewhere in the file.
extract_comment_body_printf() {
  awk '
    /COMMENT_BODY="\$\(printf .%s%s\\n\\n%s\\n\\n%s\\n\\n%s\\n\\n%s\\n\\n%s%s%s%s%s./{flag=1}
    flag{print}
    flag && /\)"$/{exit}
  ' "$YAML"
}

@test "PR comment body wires TIER2_SECTION into the printf argument list" {
  # Task 20 review fix: TIER2_SECTION was removable from this printf's
  # argument list without any test going red — sweep findings would silently
  # vanish from the comment (OSV_TOTAL still drives the verdict, so the gate
  # stays correctly red, but reporting is dark). Assert both that the arg is
  # present, and that the arg count matches the %s count in the format string
  # — a naive presence-only grep would not catch a dropped %s that shifts
  # every argument after it into the wrong slot.
  local block; block=$(extract_comment_body_printf)
  [ -n "$block" ]
  echo "$block" | grep -qF '"$TIER2_SECTION"'

  local fmt_line n_pct n_args
  fmt_line=$(echo "$block" | head -1)
  n_pct=$(printf '%s' "$fmt_line" | grep -o '%s' | wc -l | tr -d ' ')
  n_args=$(echo "$block" | tail -n +2 | grep -c '^ *"')
  [ "$n_pct" -gt 0 ]
  [ "$n_pct" -eq "$n_args" ]
}
