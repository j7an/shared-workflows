#!/usr/bin/env bats

load 'helpers/action-pin-assertions'

YAML='.github/workflows/coverage-action-canary.yml'

outcome_assertion_run_block() {
  awk '
    /^      - name: Assert expected coverage failure$/ { in_step = 1 }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run && /^      - / { exit }
    in_run {
      sub(/^          /, "")
      print
    }
  ' "$YAML"
}

run_outcome_assertion() {
  local outcome=$1 block
  block=$(outcome_assertion_run_block) || return 1
  block=$(printf '%s\n' "$block" | sed 's/${{ steps.expected-failure.outcome }}/${EXPECTED_FAILURE_OUTCOME}/g') || return 1
  run env EXPECTED_FAILURE_OUTCOME="$outcome" bash -c "$block"
}

@test "coverage canary is limited to coverage action changes" {
  grep -Fq -- "- 'actions/coverage/**'" "$YAML" || return 1
  grep -Fq -- "- 'tests/coverage-action*.bats'" "$YAML" || return 1
  grep -Fq -- "- 'tests/helpers/coverage-action-fixture.bash'" "$YAML" || return 1
  grep -Fq -- "- '.github/workflows/coverage-action-canary.yml'" "$YAML" || return 1
  grep -A2 '^permissions:$' "$YAML" | grep -Fxq '  contents: read' || return 1
}

@test "coverage canary uses pinned runner setup and real local action outcomes" {
  assert_action_pin "$(cat "$YAML")" 'step-security/harden-runner' || return 1
  assert_action_pin "$(cat "$YAML")" 'actions/checkout' || return 1

  grep -Fq 'uses: ./actions/coverage' "$YAML" || return 1
  [ "$(grep -Fc 'uses: ./actions/coverage' "$YAML")" -eq 2 ] || return 1
  grep -A18 'id: expected-failure' "$YAML" | grep -Eq '^[[:space:]]+continue-on-error: true$' || return 1
  block=$(outcome_assertion_run_block)
  [[ "$block" == *'if [ "${{ steps.expected-failure.outcome }}" != "failure" ]; then'* ]] || return 1
  [[ "$block" == *'echo "expected the coverage action to fail below threshold" >&2'* ]] || return 1
  [[ "$block" == *'exit 1'* ]] || return 1

  run_outcome_assertion failure
  [ "$status" -eq 0 ] || return 1
  run_outcome_assertion success
  [ "$status" -eq 1 ] || return 1
  [[ "$output" == *'expected the coverage action to fail below threshold'* ]] || return 1
}

@test "coverage canary builds an isolated Git fixture with checked-in report writers" {
  grep -Fq '"$GITHUB_WORKSPACE/.coverage-canary"' "$YAML" || return 1
  grep -Fq 'tests/helpers/coverage-action-fixture.bash' "$YAML" || return 1
  grep -Fq 'coverage_write_cobertura' "$YAML" || return 1
  grep -Fq 'coverage_write_lcov' "$YAML" || return 1
  grep -Fq "'diff-cover>=10.2,<11'" "$YAML" || return 1
}
