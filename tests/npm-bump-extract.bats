bats_require_minimum_version 1.5.0
#!/usr/bin/env bats

# Helper: run the extractor in one mode against a here-string diff.
run_mode() {
  local mode="$1" diff="$2"
  run bash -c "bash scripts/npm-bump-extract.sh --mode=$mode" <<< "$diff"
}

# Helper: run the extractor in one mode against a fixture file.
run_fixture() {
  local mode="$1" fixture="$2"
  run bash scripts/npm-bump-extract.sh "--mode=$mode" < "$fixture"
}

@test "empty input exits 0 with no output in every mode" {
  for mode in deps lockfile-entries cleared-paths; do
    run bash -c "bash scripts/npm-bump-extract.sh --mode=$mode" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "non-diff input exits 2" {
  run_mode deps "this is not a diff"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a unified diff"* ]]
}

@test "missing --mode exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--mode="* ]]
}

@test "repeated --mode exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh --mode=deps --mode=deps' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
}

@test "unknown argument exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh --mode=deps --bogus' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "unknown mode value exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh --mode=nonsense' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "diff with no npm files emits nothing in every mode" {
  for mode in deps lockfile-entries cleared-paths; do
    run_fixture "$mode" tests/fixtures/npm-bump-extract/unrelated-file.diff
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

# Helper: asserts a fixture is fully disqualified. All three modes must emit
# zero rows on STDOUT. Checking only --mode=deps cannot distinguish a
# disqualified file from a clean file with nothing to extract — only
# cleared-paths differs.
#
# `--separate-stderr` is required, not cosmetic. Plain `run` merges stderr into
# $output, and disqualify_lock writes its reason to stderr — so `[ -z "$output" ]`
# under plain `run` can never pass for a fixture that genuinely disqualifies.
# The diagnostic is required behaviour (it is how the workflow explains a red
# gate), so the assertion must scope to stdout rather than the diagnostic being
# suppressed. Verified on bats 1.14.0; --separate-stderr exists since 1.5.0.
assert_disqualified() {
  local fixture="$1"
  for mode in deps lockfile-entries cleared-paths; do
    run --separate-stderr bash scripts/npm-bump-extract.sh "--mode=$mode" < "$fixture"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "lockfile overrides: change disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-overrides.diff
}

@test "lockfile pnpmfileChecksum change disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-pnpmfile-checksum.diff
}

@test "unrecognized lockfile section disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-unknown-section.diff
}

@test "hunk crossing from catalogs into overrides disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-cross-section.diff
}

@test "integrity change for an unchanged version disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-integrity-only.diff
}

@test "settings change disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-settings-change.diff
}

@test "newly created lockfile disqualifies (no section context)" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-new-file.diff
}

@test "unsupported lockfileVersion disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-version-bump.diff
}

@test "multi-document lockfile disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/lock-multidoc.diff
}
