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

# === Schema validation: hard errors (exit 1, fails workflow) ===

@test "schema: entry with both 'field' and 'path_expr' fails workflow" {
  run_bumper "invalid-schema/both-keys.json" "1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "mutually exclusive" ]]
  # Target file MUST be untouched (schema error fails BEFORE apply pass)
  [ "$(jq -r .version package.json)" = "0.0.0" ]
}

@test "schema: entry with neither 'field' nor 'path_expr' fails workflow" {
  run_bumper "invalid-schema/neither-key.json" "1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "neither 'field' nor 'path_expr'" ]]
  [ "$(jq -r .version package.json)" = "0.0.0" ]
}

@test "schema: entry missing 'path' fails workflow" {
  run_bumper "invalid-schema/missing-path.json" "1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "missing 'path'" ]]
}

@test "schema: missing 'files' array fails workflow" {
  run_bumper "invalid-schema/missing-files-array.json" "1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "invalid 'files' array" ]]
}

# === Path-expression rejection (per-entry skip; security boundary) ===

@test "rejection: pipe '|' is rejected, file untouched" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/pipe.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
  [[ "$output" =~ "skipped (invalid path_expr)" ]]
}

@test "rejection: wildcard '[*]' is rejected" {
  ORIG=$(cat server.json)
  run_bumper "invalid-path-expr/wildcard.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat server.json)" = "$ORIG" ]
  [[ "$output" =~ "skipped (invalid path_expr)" ]]
}

@test "rejection: slice '[0:1]' is rejected" {
  ORIG=$(cat server.json)
  run_bumper "invalid-path-expr/slice.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat server.json)" = "$ORIG" ]
}

@test "rejection: negative index '[-1]' is rejected" {
  ORIG=$(cat server.json)
  run_bumper "invalid-path-expr/negative-index.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat server.json)" = "$ORIG" ]
}

@test "rejection: recursive descent '..' is rejected" {
  ORIG=$(cat server.json)
  run_bumper "invalid-path-expr/recursive-descent.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat server.json)" = "$ORIG" ]
}

@test "rejection: parens '()' are rejected" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/parens.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "rejection: arithmetic '+' is rejected" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/arithmetic.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "rejection: format string '@sh' is rejected" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/format-string.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "rejection: variable reference '\$ENV' is rejected" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/variable-ref.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "rejection: quoted-string key '[\"x\"]' is rejected" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/quoted-key.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

# === Anchor-bypass attempts (^ and $ on the regex) ===

@test "anchor: leading whitespace cannot bypass validator" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/leading-whitespace.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "anchor: trailing whitespace cannot bypass validator" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/trailing-whitespace.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "anchor: unanchored prefix 'xxx.version' rejected" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/unanchored-prefix.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

@test "anchor: empty path_expr is treated as missing — schema error" {
  run_bumper "invalid-path-expr/empty.json" "1.2.3"
  # Empty path_expr is jq-extracted as "" — same as not present —
  # so schema validation catches it as "neither field nor path_expr"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "neither 'field' nor 'path_expr'" ]]
}

@test "anchor: injection suffix '.version; rm -rf /' is rejected as a whole" {
  ORIG=$(cat package.json)
  run_bumper "invalid-path-expr/injection-suffix.json" "1.2.3"
  [ "$status" -eq 2 ]
  [ "$(cat package.json)" = "$ORIG" ]
}

# === Filesystem-path safety (regression coverage from inline bumper) ===

@test "filesystem: absolute path is skipped with warning" {
  run_bumper "valid/absolute-path.json" "1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "skipped (unsafe path)" ]]
}

@test "filesystem: traversal '..' is skipped with warning" {
  run_bumper "valid/traversal-path.json" "1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "skipped (unsafe path)" ]]
}

@test "filesystem: missing target file is skipped" {
  run_bumper "valid/missing-target.json" "1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "skipped (file not found)" ]]
}

@test "filesystem: non-JSON file is skipped" {
  # Create a Cargo.toml in the temp dir for this test
  echo 'version = "0.0.0"' > Cargo.toml
  run_bumper "valid/non-json-target.json" "1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "skipped (not JSON)" ]]
  # Cargo.toml must be untouched
  [ "$(cat Cargo.toml)" = 'version = "0.0.0"' ]
}

@test "filesystem: invalid-JSON target is skipped (NEW behavior)" {
  run_bumper "valid/invalid-json-target.json" "1.2.3"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "skipped (invalid JSON)" ]]
  # invalid.json is part of the targets fixture set (copied by setup())
  # and remains untouched
}

# === Step-summary table format ===

@test "summary: path_expr entry renders the full path in the Path column" {
  run_bumper "valid/path-expr-nested.json" "1.2.3"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "| \`server.json\` | \`.packages[0].version\` | \`0.0.0\` -> \`1.2.3\` | updated |" ]]
}

@test "summary: legacy field='version' renders as '.version' (unified display)" {
  run_bumper "valid/legacy-field.json" "1.2.3"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "| \`package.json\` | \`.version\` | \`0.0.0\` -> \`1.2.3\` | updated |" ]]
}

# === Multi-entry interleaving — the 'partial progress' guarantee ===

@test "interleaving: one valid entry + one invalid path_expr — valid still applied" {
  run_bumper "valid/one-good-one-bad.json" "1.2.3"
  # Exit 0 because at least one entry was modified (the valid one)
  [ "$status" -eq 0 ]
  # Valid entry: package.json updated
  [ "$(jq -r .version package.json)" = "1.2.3" ]
  # Invalid entry: server.json untouched
  [ "$(jq -r .version server.json)" = "0.0.0" ]
  [ "$(jq -r '.packages[0].version' server.json)" = "0.0.0" ]
  # Both rows appear in the summary
  [[ "$output" =~ "| \`package.json\` | \`.version\` |" ]]
  [[ "$output" =~ "skipped (invalid path_expr)" ]]
}

# === Acceptance: bracket-quoted string keys (#45) ===

@test "path_expr: quoted-key '[\"@scope/pkg\"]' bumps scoped dependency" {
  run_bumper "valid/path-expr-quoted-key-scoped.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dependencies["@scope/pkg"].version' package-scoped.json)" = "1.2.3" ]
  # Confirm the other dependency was NOT touched
  [ "$(jq -r '.dependencies["eslint-config-airbnb"].version' package-scoped.json)" = "0.0.0" ]
  # Confirm the top-level .version was NOT touched
  [ "$(jq -r '.version' package-scoped.json)" = "1.0.0" ]
}
