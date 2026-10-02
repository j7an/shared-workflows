#!/usr/bin/env bats
# Exercise the SARIF gate against real Zizmor output and unusable inputs.

FIXTURES="tests/fixtures/zizmor-sarif-gate"

run_gate() {
  run bash scripts/zizmor-sarif-gate.sh "$@"
}

@test "clean SARIF passes" {
  run_gate "$FIXTURES/clean.sarif"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Zizmor: no findings at the configured thresholds."* ]]
}

@test "findings fail and are listed" {
  run_gate "$FIXTURES/findings.sarif"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zizmor/template-injection .github/workflows/injection.yml:7"* ]]
  [[ "$output" == *"::error::Zizmor reported 1 finding(s); see the Security tab (code scanning, category: zizmor)."* ]]
}

@test "results are counted across all runs" {
  run_gate "$FIXTURES/multi-run.sarif"
  [ "$status" -eq 1 ]
  [[ "$output" == *"zizmor/a a.yml:1"* ]]
  [[ "$output" == *"zizmor/b b.yml:2"* ]]
  [[ "$output" == *"reported 2 finding(s)"* ]]
}

@test "missing argument fails closed" {
  run_gate
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "empty argument fails closed" {
  run_gate ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "nonexistent file fails closed" {
  run_gate "$BATS_TEST_TMPDIR/nope.sarif"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "empty file fails closed" {
  run_gate "$FIXTURES/empty.sarif"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "malformed JSON fails closed" {
  run_gate "$FIXTURES/malformed.sarif"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}

@test "document without runs fails closed" {
  run_gate "$FIXTURES/no-runs.sarif"
  [ "$status" -eq 2 ]
  [[ "$output" == *"::error::"* ]]
}
