#!/usr/bin/env bats

# Tests for scripts/image-vuln-diff.sh. Real fixtures (deprank-266-*) are Trivy
# output; synthetic-* fixtures cover directions the real pair does not.

FIX="tests/fixtures/image-vuln-diff"
TAB=$'\t'

setup() {
  export IMAGE_DIFF_NOW
  # 2 hours after the real fixture's DB UpdatedAt (2026-11-16T01:11:02Z).
  IMAGE_DIFF_NOW=$(( $(jq -r '.VulnerabilityDB.UpdatedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' "$FIX/db-version.json") + 7200 ))
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPD"
}

# Run with stdout and stderr separated (bats `run` merges them).
run_split() {
  local rc
  "$@" >"$TMPD/out" 2>"$TMPD/err" && rc=0 || rc=$?
  status=$rc
  output="$(cat "$TMPD/out")"
  errout="$(cat "$TMPD/err")"
}

run_diff() { run_split bash scripts/image-vuln-diff.sh "$@"; }

assert_fail_token() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(head -n1 "$TMPD/err")" = "$1" ]
}

db_at_age_hours() {
  # Write a DB json whose UpdatedAt is $1 hours before IMAGE_DIFF_NOW.
  local t=$(( IMAGE_DIFF_NOW - $1 * 3600 ))
  jq -n --argjson t "$t" \
    '{VulnerabilityDB:{UpdatedAt:($t|todate|sub("Z$";".123456789Z"))}}' > "$TMPD/db.json"
}

@test "deprank-266 fixtures produce the recorded delta" {
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$FIX/deprank-266-new.json"
  [ "$status" -eq 0 ]
  expected="fixed${TAB}fixable${TAB}os${TAB}CVE-2026-109518${TAB}apt${TAB}3.0.3${TAB}3.0.4${TAB}HIGH
fixed${TAB}fixable${TAB}os${TAB}CVE-2026-109518${TAB}libapt-pkg7.0${TAB}3.0.3${TAB}3.0.4${TAB}HIGH"
  [ "$output" = "$expected" ]
}

@test "shared id+pkg with changed InstalledVersion is not in the delta" {
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$FIX/deprank-266-new.json"
  [ "$status" -eq 0 ]
  [[ "$output" != *CVE-2011-3374* ]]
}

@test "introduced fixable vs unfixed split" {
  run_diff "$FIX/db-version.json" "$FIX/synthetic-old.json" "$FIX/synthetic-new.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx "introduced${TAB}fixable${TAB}os${TAB}CVE-0000-0001${TAB}pkg-n${TAB}3.0${TAB}3.1${TAB}HIGH"
  printf '%s\n' "$output" | grep -qx "introduced${TAB}unfixed${TAB}os${TAB}CVE-0000-0002${TAB}pkg-m${TAB}1.0${TAB}-${TAB}MEDIUM"
}

@test "fixed vuln reported with old-side fixability" {
  run_diff "$FIX/db-version.json" "$FIX/synthetic-old.json" "$FIX/synthetic-new.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx "fixed${TAB}fixable${TAB}os${TAB}CVE-0000-0003${TAB}pkg-a${TAB}1.0${TAB}2.0${TAB}HIGH"
  printf '%s\n' "$output" | grep -qx "fixed${TAB}unfixed${TAB}os${TAB}CVE-0000-0004${TAB}pkg-b${TAB}1.0${TAB}-${TAB}LOW"
}

@test "same id+pkg in os and lang classes are distinct keys" {
  run_diff "$FIX/db-version.json" "$FIX/synthetic-old.json" "$FIX/synthetic-new.json"
  [ "$status" -eq 0 ]
  # Only the lang entry for pkg-d disappears; the os entry persists.
  printf '%s\n' "$output" | grep -qx "fixed${TAB}fixable${TAB}lang${TAB}CVE-0000-0005${TAB}pkg-d${TAB}1.0${TAB}1.1${TAB}MEDIUM"
  [ "$(printf '%s\n' "$output" | grep -c 'CVE-0000-0005')" -eq 1 ]
}

@test "full synthetic output is sorted, and ignores other result classes and shared keys" {
  run_diff "$FIX/db-version.json" "$FIX/synthetic-old.json" "$FIX/synthetic-new.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 5 ]
  [ "$output" = "$(printf '%s\n' "$output" | LC_ALL=C sort -u)" ]
  [[ "$output" != *CVE-0000-0777* ]]
  [[ "$output" != *CVE-0000-0099* ]]
}

@test "identical images produce no output, exit 0" {
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-new.json" "$FIX/deprank-266-new.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "zero packages in old image fails with no-packages-old" {
  jq '.Results |= map(del(.Packages))' "$FIX/deprank-266-old.json" > "$TMPD/old.json"
  run_diff "$FIX/db-version.json" "$TMPD/old.json" "$FIX/deprank-266-new.json"
  assert_fail_token no-packages-old
}

@test "zero packages in new image fails with no-packages-new" {
  jq '.Results = []' "$FIX/deprank-266-new.json" > "$TMPD/new.json"
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$TMPD/new.json"
  assert_fail_token no-packages-new
}

@test "DB UpdatedAt 73h old fails with trivy-db-stale" {
  db_at_age_hours 73
  run_diff "$TMPD/db.json" "$FIX/deprank-266-old.json" "$FIX/deprank-266-new.json"
  assert_fail_token trivy-db-stale
}

@test "DB UpdatedAt 71h old passes" {
  db_at_age_hours 71
  run_diff "$TMPD/db.json" "$FIX/deprank-266-old.json" "$FIX/deprank-266-new.json"
  [ "$status" -eq 0 ]
}

@test "DB json without UpdatedAt fails with invalid-json" {
  echo '{}' > "$TMPD/db.json"
  run_diff "$TMPD/db.json" "$FIX/deprank-266-old.json" "$FIX/deprank-266-new.json"
  assert_fail_token invalid-json
}

@test "truncated JSON fails with invalid-json" {
  head -c 200 "$FIX/deprank-266-new.json" > "$TMPD/new.json"
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$TMPD/new.json"
  assert_fail_token invalid-json
}

@test "missing file fails with invalid-json" {
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$TMPD/nonexistent.json"
  assert_fail_token invalid-json
}

@test "missing arg fails with usage" {
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json"
  assert_fail_token usage
}

@test "new image config architecture arm64 fails with platform-mismatch-new" {
  jq '.Metadata.ImageConfig.architecture = "arm64"' "$FIX/deprank-266-new.json" > "$TMPD/new.json"
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$TMPD/new.json"
  assert_fail_token platform-mismatch-new
}

@test "old image config missing os/architecture fails with platform-mismatch-old" {
  jq 'del(.Metadata.ImageConfig.os, .Metadata.ImageConfig.architecture)' "$FIX/deprank-266-old.json" > "$TMPD/old.json"
  run_diff "$FIX/db-version.json" "$TMPD/old.json" "$FIX/deprank-266-new.json"
  assert_fail_token platform-mismatch-old
}

@test "non-array Vulnerabilities fails with invalid-json as stderr line 1" {
  jq '.Results[0].Vulnerabilities = "x"' "$FIX/deprank-266-new.json" > "$TMPD/new.json"
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$TMPD/new.json"
  assert_fail_token invalid-json
}

@test "vuln entry missing VulnerabilityID or PkgName fails with invalid-json" {
  jq '.Results[0].Vulnerabilities[0] |= del(.VulnerabilityID)' "$FIX/deprank-266-new.json" > "$TMPD/new.json"
  run_diff "$FIX/db-version.json" "$FIX/deprank-266-old.json" "$TMPD/new.json"
  assert_fail_token invalid-json
  jq '.Results[0].Vulnerabilities[0] |= del(.PkgName)' "$FIX/deprank-266-old.json" > "$TMPD/old.json"
  run_diff "$FIX/db-version.json" "$TMPD/old.json" "$FIX/deprank-266-new.json"
  assert_fail_token invalid-json
}
