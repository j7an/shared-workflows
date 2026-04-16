#!/usr/bin/env bats

# lint-workflow-call.bats — tests for scripts/lint-workflow-call.sh
#
# The lint script scans .github/workflows/*.yml for workflow_call files
# containing forbidden caller-context refs. Tests use a temp directory
# with fixture files symlinked into .github/workflows/ to simulate
# the real repo layout.

setup() {
  LINT="$BATS_TEST_DIRNAME/../scripts/lint-workflow-call.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/lint-workflow-call"
  WORKDIR=$(mktemp -d)
  mkdir -p "$WORKDIR/.github/workflows"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "passes on clean workflow_call file" {
  cp "$FIXTURES/clean.yml" "$WORKDIR/.github/workflows/clean.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "fails on ref: github.workflow_sha in workflow_call file" {
  cp "$FIXTURES/forbidden-workflow-sha.yml" "$WORKDIR/.github/workflows/bad.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "github.workflow_sha" ]]
}

@test "fails on ref: github.sha in workflow_call file" {
  cp "$FIXTURES/forbidden-sha.yml" "$WORKDIR/.github/workflows/bad.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "github.sha" ]]
}

@test "fails on ref: github.ref in workflow_call file" {
  cp "$FIXTURES/forbidden-ref.yml" "$WORKDIR/.github/workflows/bad.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "github.ref" ]]
}

@test "skips non-workflow_call files even if they contain forbidden refs" {
  cp "$FIXTURES/not-reusable.yml" "$WORKDIR/.github/workflows/ci.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "passes when .github/workflows/ has no files" {
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 0 ]
}

@test "fails listing all violations when multiple bad files exist" {
  cp "$FIXTURES/forbidden-workflow-sha.yml" "$WORKDIR/.github/workflows/bad1.yml"
  cp "$FIXTURES/forbidden-sha.yml" "$WORKDIR/.github/workflows/bad2.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "bad1.yml" ]]
  [[ "$output" =~ "bad2.yml" ]]
}

@test "passes when .github/workflows/ directory does not exist" {
  empty=$(mktemp -d)
  run bash "$LINT" "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "nothing to lint" ]]
  rm -rf "$empty"
}

@test "skips files that mention workflow_call only in comments" {
  cp "$FIXTURES/comment-mention.yml" "$WORKDIR/.github/workflows/ci.yml"
  run bash "$LINT" "$WORKDIR"
  [ "$status" -eq 0 ]
}
