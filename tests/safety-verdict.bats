#!/usr/bin/env bats

# Helper: invoke safety-verdict.sh with full env, capture stdout (status).
# Tests parse the single TSV line into named fields for assertions.
# Note: bats `run` merges stderr into $output — fail-closed tests assert
# diagnostics there.
run_verdict() {
  run bash scripts/safety-verdict.sh
}

# Helper: split last-output TSV line into named globals.
parse_tsv() {
  IFS=$'\t' read -r GATE_STATE AUTO_MERGE_OK HAS_SAFETY_ERROR \
                    HAS_AGE_VIOLATION HAS_SECURITY_REVIEW STATUS_DESC \
                    <<< "$output"
}

# Default env: clean state under the strictest policy (blocking), so the
# age-violation tests inherit v3-equivalent semantics. Individual tests
# override RELEASE_AGE_POLICY to advisory/off as needed.
setup() {
  export GUARD_TRIGGERED=false
  export AGE_ERROR_COUNT=0
  export AGE_VIOLATION_COUNT=0
  export SCAN_ERROR_COUNT=0
  export ADVISORY_COUNT=0
  export RELEASE_AGE_POLICY=blocking
  export MINIMUM_RELEASE_AGE_DAYS=5
  export AUTO_MERGE=false
}

@test "clean + AUTO_MERGE=true (blocking) → success, auto_merge_ok=true, age text present" {
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "true" ]
  [ "$HAS_SAFETY_ERROR" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "false" ]
  [ "$HAS_SECURITY_REVIEW" = "false" ]
  [ "$STATUS_DESC" = "Clean scan (≥5d, no advisories). Auto-merge enabled." ]
}

@test "clean + AUTO_MERGE=false (blocking) → success, auto_merge_ok=false" {
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$STATUS_DESC" = "Clean scan (≥5d, no advisories). Ready for merge." ]
}

@test "clean + policy=advisory → success, age text present" {
  export RELEASE_AGE_POLICY=advisory
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$STATUS_DESC" = "Clean scan (≥5d, no advisories). Ready for merge." ]
}

@test "clean + policy=off + AUTO_MERGE=true → success, auto_merge_ok=true, no age text" {
  export RELEASE_AGE_POLICY=off
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "true" ]
  [ "$STATUS_DESC" = "Clean scan (no advisories). Auto-merge enabled." ]
}

@test "clean + policy=off + AUTO_MERGE=false → success, no age text" {
  export RELEASE_AGE_POLICY=off
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$STATUS_DESC" = "Clean scan (no advisories). Ready for merge." ]
}

@test "advisory finding only → success, has_security_review=true, auto_merge_ok=false" {
  export ADVISORY_COUNT=2
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_SECURITY_REVIEW" = "true" ]
  [[ "$STATUS_DESC" == *"2 advisory"* ]]
}

@test "age violation + policy=blocking → failure" {
  export AGE_VIOLATION_COUNT=1
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "failure" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "true" ]
  [[ "$STATUS_DESC" == *"younger than 5d minimum release age (blocking policy)"* ]]
}

@test "age violation + policy=advisory → success, label still applied, auto_merge_ok=false" {
  export AGE_VIOLATION_COUNT=3
  export RELEASE_AGE_POLICY=advisory
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "true" ]
  [[ "$STATUS_DESC" == *"advisory policy"* ]]
  [[ "$STATUS_DESC" == *"Auto-merge suppressed"* ]]
}

@test "age lookup error + policy=blocking → error, has_safety_error=true" {
  export AGE_ERROR_COUNT=1
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
  [[ "$STATUS_DESC" == *"Scan errors"* ]]
}

@test "age lookup error + policy=advisory → error (fail-closed even when non-blocking)" {
  export AGE_ERROR_COUNT=1
  export RELEASE_AGE_POLICY=advisory
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
}

@test "scan error (GHSA/OSV) → error, has_safety_error=true" {
  export SCAN_ERROR_COUNT=2
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
}

@test "scan error + policy=off → error (advisory-scan errors still fail closed)" {
  export RELEASE_AGE_POLICY=off
  export SCAN_ERROR_COUNT=1
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
}

@test "guard triggered → error, has_safety_error=true" {
  export GUARD_TRIGGERED=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
  [[ "$STATUS_DESC" == *"Could not extract"* ]]
}

@test "multi: scan_error + age_violation + advisory → error wins, all labels true" {
  export SCAN_ERROR_COUNT=1
  export AGE_VIOLATION_COUNT=1
  export ADVISORY_COUNT=1
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
  [ "$HAS_AGE_VIOLATION" = "true" ]
  [ "$HAS_SECURITY_REVIEW" = "true" ]
}

@test "clean age + multiple advisories → success, only has_security_review=true" {
  export ADVISORY_COUNT=5
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$HAS_SAFETY_ERROR" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "false" ]
  [ "$HAS_SECURITY_REVIEW" = "true" ]
}

@test "missing required env → non-zero exit (fail-closed)" {
  unset GUARD_TRIGGERED
  run_verdict
  [ "$status" -ne 0 ]
}

@test "invalid bool env → non-zero exit (fail-closed)" {
  export GUARD_TRIGGERED=maybe
  run_verdict
  [ "$status" -ne 0 ]
}

@test "negative int env → non-zero exit (fail-closed)" {
  export ADVISORY_COUNT=-1
  run_verdict
  [ "$status" -ne 0 ]
}

@test "RELEASE_AGE_POLICY unset → non-zero exit (fail-closed)" {
  unset RELEASE_AGE_POLICY
  run_verdict
  [ "$status" -ne 0 ]
}

@test "RELEASE_AGE_POLICY=bogus → non-zero exit (fail-closed)" {
  export RELEASE_AGE_POLICY=bogus
  run_verdict
  [ "$status" -ne 0 ]
}

@test "RELEASE_AGE_POLICY=false → non-zero exit with YAML quoting hint" {
  export RELEASE_AGE_POLICY=false
  run_verdict
  [ "$status" -ne 0 ]
  [[ "$output" == *"quote it"* ]]
}

@test "policy=off + AGE_VIOLATION_COUNT>0 → non-zero exit (orchestrator-bug invariant)" {
  export RELEASE_AGE_POLICY=off
  export AGE_VIOLATION_COUNT=1
  run_verdict
  [ "$status" -ne 0 ]
  [[ "$output" == *"orchestrator bug"* ]]
}

@test "policy=off + AGE_ERROR_COUNT>0 → non-zero exit (orchestrator-bug invariant)" {
  export RELEASE_AGE_POLICY=off
  export AGE_ERROR_COUNT=2
  run_verdict
  [ "$status" -ne 0 ]
  [[ "$output" == *"orchestrator bug"* ]]
}
