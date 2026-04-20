#!/usr/bin/env bats

# bump-version-files.bats — tests for scripts/bump-version-files.sh
#
# Each test copies fixture targets into a temp dir, runs the script
# against a config fixture, asserts post-state of target files plus
# the script's stdout summary rows.

setup() {
  TMPDIR=$(mktemp -d)
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  cp "$REPO_ROOT"/tests/fixtures/bump-version-files/targets/*.json "$TMPDIR/"
  cd "$TMPDIR"
}

teardown() {
  cd /
  rm -rf "$TMPDIR"
}

run_bumper() {
  local config="$1" version="$2"
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/$config" .version-bump.json
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json "$version"
}

# === Acceptance: legacy `field` codepath ===

@test "legacy: field='version' bumps top-level .version" {
  run_bumper "valid/legacy-field.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version package.json)" = "1.2.3" ]
}

@test "legacy: idempotent re-run reports 'already up to date'" {
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" .version-bump.json
  bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 1.2.3
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 1.2.3
  [ "$status" -eq 2 ]
  [[ "$output" =~ "already up to date" ]]
}
