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
