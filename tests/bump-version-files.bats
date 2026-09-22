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
  # Per-test manifest path. The script defaults to a shared /tmp/bump.modified;
  # pinning it inside this test's unique TMPDIR keeps parallel/concurrent runs
  # from clobbering one another (teardown's rm -rf cleans it up).
  export BUMP_MODIFIED_FILE="$TMPDIR/bump.modified"
  # The config must resolve inside GITHUB_WORKSPACE. CI runners export the
  # real checkout here, so pin it to this test's checkout stand-in.
  export GITHUB_WORKSPACE="$TMPDIR"
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

@test "invalid nonempty path expressions are rejected without modifying targets" {
  local fixture target seen=0
  for fixture in "$REPO_ROOT"/tests/fixtures/bump-version-files/invalid-path-expr/*.json; do
    [ -f "$fixture" ] || { printf 'missing rejection fixtures\n' >&2; return 1; }
    [ "${fixture##*/}" = empty.json ] && continue
    target=$(jq -er '.files[0].path' "$fixture") || return 1
    run_bumper "invalid-path-expr/${fixture##*/}" "1.2.3"
    if [ "$status" -ne 2 ] || [[ "$output" != *'skipped (invalid path_expr)'* ]] ||
       ! cmp -s "$target" "$REPO_ROOT/tests/fixtures/bump-version-files/targets/$target"; then
      printf 'rejection failed: %s; status=%s; output=%s\n' "$fixture" "$status" "$output" >&2
      return 1
    fi
    seen=$((seen + 1))
  done
  [ "$seen" -gt 0 ]
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

# === Anchor-bypass attempts (^ and $ on the regex) ===

@test "anchor: empty path_expr is treated as missing — schema error" {
  run_bumper "invalid-path-expr/empty.json" "1.2.3"
  # Empty path_expr is jq-extracted as "" — same as not present —
  # so schema validation catches it as "neither field nor path_expr"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "neither 'field' nor 'path_expr'" ]]
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

@test "summary: '[]' iterator renders verbatim in step-summary path column" {
  run_bumper "valid/path-expr-iterate-all.json" "1.2.3"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "| \`multi-pkg-server.json\` | \`.packages[].version\` |" ]]
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

# === Acceptance: [] iterator (#46) ===

@test "path_expr: '[]' iterator updates every array element" {
  run_bumper "valid/path-expr-iterate-all.json" "1.2.3"
  [ "$status" -eq 0 ]
  # All three .packages[].version entries are updated
  [ "$(jq -r '.packages[0].version' multi-pkg-server.json)" = "1.2.3" ]
  [ "$(jq -r '.packages[1].version' multi-pkg-server.json)" = "1.2.3" ]
  [ "$(jq -r '.packages[2].version' multi-pkg-server.json)" = "1.2.3" ]
  # Top-level .version is NOT touched
  [ "$(jq -r '.version' multi-pkg-server.json)" = "0.0.0" ]
}

@test "path_expr: quoted-key with kebab-case hyphens is bumped" {
  run_bumper "valid/path-expr-quoted-key-kebab.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.dependencies["eslint-config-airbnb"].version' package-scoped.json)" = "1.2.3" ]
  # Sibling dependency was NOT touched
  [ "$(jq -r '.dependencies["@scope/pkg"].version' package-scoped.json)" = "0.0.0" ]
}

# === Manifest emission: bump.modified contract (#issue-cross-agent-12) ===
# Manifest must be a UNIQUE PATH SET — see spec §3.1 step 2. The Git Data API
# rewrite of tag-release.yml consumes this file to build POST /git/trees;
# duplicates would produce duplicate tree[] entries with undefined behavior.
# Each test reads $BUMP_MODIFIED_FILE (a per-test path exported in setup),
# not the shared /tmp default, so concurrent runs stay isolated.

@test "manifest: bump.modified is unique path set after multi-entry-same-file run" {
  run_bumper "valid/multi-entry-same-file.json" "1.2.3"
  [ "$status" -eq 0 ]
  [ -f "$BUMP_MODIFIED_FILE" ]
  # Exactly one line: server.json (despite TWO entries targeting it)
  [ "$(wc -l < "$BUMP_MODIFIED_FILE")" -eq 1 ]
  [ "$(cat "$BUMP_MODIFIED_FILE")" = "server.json" ]
}

@test "manifest: bump.modified contains all unique modified paths in mixed run" {
  run_bumper "valid/mixed-old-and-new.json" "1.2.3"
  [ "$status" -eq 0 ]
  # mixed-old-and-new.json bumps package.json (legacy field) AND server.json (path_expr).
  # `< file` redirect makes the assertion fail loudly if the manifest is missing,
  # rather than passing a stray empty string into the comparison.
  expected=$(printf 'package.json\nserver.json\n')
  [ "$(sort < "$BUMP_MODIFIED_FILE")" = "$expected" ]
}

@test "manifest: bump.modified is empty when no entries are updated (idempotent rerun)" {
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" .version-bump.json
  bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 1.2.3  # First run: bumps
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 1.2.3  # Second run: no-op
  [ "$status" -eq 2 ]
  [ -f "$BUMP_MODIFIED_FILE" ]
  [ ! -s "$BUMP_MODIFIED_FILE" ]  # File exists but is empty
}

@test "manifest: bump.modified is truncated on each invocation (no cross-run pollution)" {
  # Run 1: bump multi-entry-same-file (writes "server.json")
  run_bumper "valid/multi-entry-same-file.json" "1.2.3"
  [ "$status" -eq 0 ]
  # Run 2: idempotent rerun of legacy-field. First bump 0.0.0 -> 9.9.9 succeeds;
  # second bump 9.9.9 -> 9.9.9 is a no-op (exit 2). The manifest after run 2
  # must still be truncated (empty) AND must NOT carry server.json across.
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" .version-bump.json
  bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 9.9.9  # First bump
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" .version-bump.json 9.9.9  # Idempotent rerun
  [ "$status" -eq 2 ]
  # File-existence guard prevents this from passing vacuously when the
  # script doesn't yet create the manifest (red phase): grep on a missing
  # file returns 1, and `! grep` would silently succeed without it.
  [ -f "$BUMP_MODIFIED_FILE" ]
  ! grep -q server.json "$BUMP_MODIFIED_FILE"
}

# === Config path contract (version-bump-config input, #167) ===

run_config() {
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" "$1" 1.2.3
}

assert_config_rejected() {
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::"* ]]
  [ "$(jq -r .version package.json)" = "0.0.0" ]
  [ ! -s "$BUMP_MODIFIED_FILE" ]
}

@test "config: default argument still reads root .version-bump.json" {
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" .version-bump.json
  run bash "$REPO_ROOT/scripts/bump-version-files.sh" "" 1.2.3
  [ "$status" -eq 0 ]
  [ "$(jq -r .version package.json)" = "1.2.3" ]
}

@test "config: absolute path is rejected" {
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" cfg.json
  run_config "$TMPDIR/cfg.json"
  assert_config_rejected
  [[ "$output" == *"absolute"* ]]
}

@test "config: '..' segment is rejected even when it resolves inside" {
  mkdir sub
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" cfg.json
  run_config "sub/../cfg.json"
  assert_config_rejected
  [[ "$output" == *"'..'"* ]]
}

@test "config: non-.json name is rejected" {
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" cfg.yml
  run_config "cfg.yml"
  assert_config_rejected
  [[ "$output" == *".json"* ]]
}

@test "config: control characters are rejected" {
  run_config "$(printf 'a\nb.json')"
  assert_config_rejected
  [[ "$output" == *"control character"* ]]
}

@test "config: symlinked config file is rejected" {
  outside=$(mktemp -d)
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" "$outside/cfg.json"
  ln -s "$outside/cfg.json" link.json
  run_config "link.json"
  rm -rf "$outside"
  assert_config_rejected
  [[ "$output" == *"symlink"* ]]
}

@test "config: directory symlink escaping the workspace is rejected" {
  outside=$(mktemp -d)
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/valid/legacy-field.json" "$outside/cfg.json"
  ln -s "$outside" escape
  run_config "escape/cfg.json"
  rm -rf "$outside"
  assert_config_rejected
  [[ "$output" == *"outside"* ]]
}

@test "config: absent named config is a no-op" {
  run_config ".version-bump.missing.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"No .version-bump.missing.json found"* ]]
  [ "$(jq -r .version package.json)" = "0.0.0" ]
  [ ! -s "$BUMP_MODIFIED_FILE" ]
}

@test "config: schema errors name the selected config" {
  cp "$REPO_ROOT/tests/fixtures/bump-version-files/invalid-path-expr/pipe.json" .version-bump.pkg.json
  run_config ".version-bump.pkg.json"
  [[ "$output" == *"file=.version-bump.pkg.json::"* ]]
}

@test "monorepo: each config bumps only its own package manifest" {
  cp -R "$REPO_ROOT/tests/fixtures/bump-version-files/monorepo/." .
  run_config ".version-bump.permissions.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .version packages/permissions/package.json)" = "1.2.3" ]
  [ "$(jq -r .version packages/other/package.json)" = "0.3.0" ]
  [ "$(cat "$BUMP_MODIFIED_FILE")" = "packages/permissions/package.json" ]
}
