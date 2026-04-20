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

# === Acceptance: path_expr codepath ===

@test "path_expr: '.version' bumps top-level (equivalent to legacy field)" {
  run_bumper "valid/path-expr-simple.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version package.json)" = "1.2.3" ]
}

@test "path_expr: '.packages[0].version' bumps nested array element" {
  run_bumper "valid/path-expr-nested.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.packages[0].version' server.json)" = "1.2.3" ]
  # Confirm the top-level .version was NOT touched
  [ "$(jq -r .version server.json)" = "0.0.0" ]
}

@test "path_expr: '.packages[1].version' touches only that index" {
  run_bumper "valid/path-expr-indexed.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.packages[0].version' multi-pkg-server.json)" = "0.0.0" ]
  [ "$(jq -r '.packages[1].version' multi-pkg-server.json)" = "1.2.3" ]
  [ "$(jq -r '.packages[2].version' multi-pkg-server.json)" = "0.0.0" ]
  [ "$(jq -r '.version' multi-pkg-server.json)" = "0.0.0" ]
}

# === Security boundary smoke (I4 mitigation — full coverage in T8/T9) ===

@test "validator: rejects path_expr with pipe (smoke; T8 has full coverage)" {
  cat > .version-bump.json <<'JSON'
{ "files": [ { "path": "package.json", "path_expr": ".version | input_filename" } ] }
JSON
  ORIG=$(cat package.json)
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 1.2.3
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
  [[ "$output" =~ "skipped (invalid path_expr)" ]]
}

@test "path_expr: deeply nested (3+ levels) is bumped" {
  run_bumper "valid/path-expr-deep.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.metadata.release.semver' deeply-nested.json)" = "1.2.3" ]
}

@test "multi-entry: two path_expr entries against same file write both" {
  run_bumper "valid/multi-entry-same-file.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.version' server.json)" = "1.2.3" ]
  [ "$(jq -r '.packages[0].version' server.json)" = "1.2.3" ]
}

@test "mixed: legacy field entry + path_expr entry both apply" {
  run_bumper "valid/mixed-old-and-new.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version package.json)" = "1.2.3" ]
  [ "$(jq -r '.packages[0].version' server.json)" = "1.2.3" ]
}
