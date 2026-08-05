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

@test "importers bump emits one tier-1 row per changed base version" {
  run_fixture deps tests/fixtures/npm-bump-extract/lock-simple-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@commitlint/cli\t21.0.2\tnpm\n@commitlint/config-conventional\t21.0.2\tnpm')" ]
}

@test "peer-suffix-only change emits no tier-1 row" {
  run_fixture deps tests/fixtures/npm-bump-extract/lock-peer-suffix-only.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "catalogs bump emits a tier-1 row" {
  run_fixture deps tests/fixtures/npm-bump-extract/lock-catalog-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@babel/core\t7.29.7\tnpm')" ]
}

@test "specifier-only change emits no row and does not disqualify" {
  run_fixture deps tests/fixtures/npm-bump-extract/lock-specifier-only.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run_fixture cleared-paths tests/fixtures/npm-bump-extract/lock-specifier-only.diff
  [ "$status" -eq 0 ]
  [ "$output" = "pnpm-lock.yaml" ]
}

@test "same package at two versions in two importers yields two rows" {
  run_fixture deps tests/fixtures/npm-bump-extract/lock-two-versions.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'lodash\t4.17.21\tnpm\nlodash\t5.0.1\tnpm')" ]
}

@test "tier-2 collects newly added packages entries, skipping snapshots" {
  run_fixture lockfile-entries tests/fixtures/npm-bump-extract/lock-packages-added.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@commitlint/cli\t21.0.2\tnpm\nterser\t5.48.0\tnpm')" ]
}

@test "tier-2 does not leak into tier-1 output" {
  run_fixture deps tests/fixtures/npm-bump-extract/lock-packages-added.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clean manifest plus lock clears both paths and emits the row" {
  run_fixture deps tests/fixtures/npm-bump-extract/manifest-and-lock-clean.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '@commitlint/cli\t21.0.2\tnpm')" ]
  run_fixture cleared-paths tests/fixtures/npm-bump-extract/manifest-and-lock-clean.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'package.json\npnpm-lock.yaml')" ]
}

@test "lifecycle script in manifest disqualifies everything" {
  assert_disqualified tests/fixtures/npm-bump-extract/manifest-postinstall.diff
}

@test "manifest dep with no matching lock entry disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/manifest-uncorroborated.diff
}

@test "manifest without a lockfile disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/manifest-without-lock.diff
}

@test "packageManager-only change disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/manifest-package-manager.diff
}

@test "dependency added without replacement disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/manifest-added-dep.diff
}

@test "dependency removed without replacement disqualifies" {
  assert_disqualified tests/fixtures/npm-bump-extract/manifest-removed-dep.diff
}

@test "wildcard and union ranges are accepted, not rejected" {
  run_fixture cleared-paths tests/fixtures/npm-bump-extract/manifest-exotic-ranges.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'package.json\npnpm-lock.yaml')" ]
}

@test "grouped monorepo: rows from lock, all paths cleared" {
  run_fixture deps tests/fixtures/npm-bump-extract/real-grouped-monorepo.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'lucide-react\t1.28.0\tnpm\nturbo\t2.10.8\tnpm')" ]

  run_fixture cleared-paths tests/fixtures/npm-bump-extract/real-grouped-monorepo.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'apps/desktop/package.json\npackage.json\npnpm-lock.yaml')" ]
}

@test "grouped monorepo: bare-major range does not become a version" {
  # "@vitest/coverage-v8": "^4" is a context line here. This asserts no row
  # ever carries a bare major as its version.
  run_fixture deps tests/fixtures/npm-bump-extract/real-grouped-monorepo.diff
  [ "$status" -eq 0 ]
  ! [[ "$output" =~ $'\t'4$'\t' ]]
}

@test "lockfile-only security update: zero tier-1 rows, tier-2 swept, path cleared" {
  run_fixture deps tests/fixtures/npm-bump-extract/real-lockfile-only.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run_fixture lockfile-entries tests/fixtures/npm-bump-extract/real-lockfile-only.diff
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'minimist\t1.2.8\tnpm')" ]

  run_fixture cleared-paths tests/fixtures/npm-bump-extract/real-lockfile-only.diff
  [ "$status" -eq 0 ]
  [ "$output" = "pnpm-lock.yaml" ]
}
