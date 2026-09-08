#!/usr/bin/env bats

load 'helpers/action-pin-assertions'

YAML='.github/workflows/coverage-action-canary.yml'

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
  grep -Fq 'steps.expected-failure.outcome' "$YAML" || return 1
  grep -Fq 'expected the coverage action to fail below threshold' "$YAML" || return 1
}

@test "coverage canary builds an isolated Git fixture with checked-in report writers" {
  grep -Fq '"$GITHUB_WORKSPACE/.coverage-canary"' "$YAML" || return 1
  grep -Fq 'tests/helpers/coverage-action-fixture.bash' "$YAML" || return 1
  grep -Fq 'coverage_write_cobertura' "$YAML" || return 1
  grep -Fq 'coverage_write_lcov' "$YAML" || return 1
  grep -Fq "'diff-cover>=10.2,<11'" "$YAML" || return 1
}
