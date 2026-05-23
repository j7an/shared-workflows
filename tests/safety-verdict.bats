#!/usr/bin/env bats

# Helper: invoke safety-verdict.sh with full env, capture stdout (status).
# Tests parse the single TSV line into named fields for assertions.
run_verdict() {
  run bash scripts/safety-verdict.sh
}

# Helper: split last-output TSV line into named globals.
parse_tsv() {
  IFS=$'\t' read -r GATE_STATE AUTO_MERGE_OK HAS_SAFETY_ERROR \
                    HAS_AGE_VIOLATION HAS_SECURITY_REVIEW STATUS_DESC \
                    <<< "$output"
}

# Default env: clean state. Individual tests override.
setup() {
  export GUARD_TRIGGERED=false
  export AGE_ERROR_COUNT=0
  export AGE_VIOLATION_COUNT=0
  export SCAN_ERROR_COUNT=0
  export ADVISORY_COUNT=0
  export FAIL_ON_AGE_VIOLATION=true
  export MINIMUM_RELEASE_AGE_DAYS=5
  export AUTO_MERGE=false
}

@test "clean + AUTO_MERGE=true → success, auto_merge_ok=true" {
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "true" ]
  [ "$HAS_SAFETY_ERROR" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "false" ]
  [ "$HAS_SECURITY_REVIEW" = "false" ]
  [[ "$STATUS_DESC" == *"Auto-merge enabled"* ]]
}

@test "clean + AUTO_MERGE=false → success, auto_merge_ok=false" {
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [[ "$STATUS_DESC" == *"Ready for merge"* ]]
}

@test "advisory only → success, has_security_review=true, auto_merge_ok=false" {
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

@test "age violation + FAIL_ON_AGE_VIOLATION=true → failure" {
  export AGE_VIOLATION_COUNT=1
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "failure" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "true" ]
  [[ "$STATUS_DESC" == *"younger than 5d"* ]]
}

@test "age violation + FAIL_ON_AGE_VIOLATION=false → success, label still applied, auto_merge_ok=false" {
  export AGE_VIOLATION_COUNT=3
  export FAIL_ON_AGE_VIOLATION=false
  export AUTO_MERGE=true
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "success" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_AGE_VIOLATION" = "true" ]
  [[ "$STATUS_DESC" == *"advisory mode"* ]]
}

@test "age lookup error → error, has_safety_error=true" {
  export AGE_ERROR_COUNT=1
  run_verdict
  [ "$status" -eq 0 ]
  parse_tsv
  [ "$GATE_STATE" = "error" ]
  [ "$AUTO_MERGE_OK" = "false" ]
  [ "$HAS_SAFETY_ERROR" = "true" ]
  [[ "$STATUS_DESC" == *"Scan errors"* ]]
}

@test "scan error (GHSA/OSV) → error, has_safety_error=true" {
  export SCAN_ERROR_COUNT=2
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
