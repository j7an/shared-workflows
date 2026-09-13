#!/usr/bin/env bats

setup() {
  export SCAN_ROOT="$BATS_TEST_DIRNAME/.."
  export SCAN_BLOCK="$BATS_TEST_TMPDIR/scanner.sh"
  export SCAN_DRIVER="$BATS_TEST_TMPDIR/driver.sh"
  export SCAN_GHSA_FILE="$BATS_TEST_TMPDIR/ghsa.json"
  export SCAN_OSV_FILE="$BATS_TEST_TMPDIR/osv.json"
  export SCAN_GH_ARGS="$BATS_TEST_TMPDIR/gh-args"
  export SCAN_OSV_BODY="$BATS_TEST_TMPDIR/osv-body"
  mkdir "$BATS_TEST_TMPDIR/bin"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  printf '%s\n' '{"data":{"securityVulnerabilities":{"nodes":[]}}}' > "$SCAN_GHSA_FILE"
  printf '%s\n' '{}' > "$SCAN_OSV_FILE"
  awk '
    /# --- BEGIN tier-1 scanner ---/ { inside=1; next }
    /# --- END tier-1 scanner ---/ { exit }
    inside { sub(/^          /, ""); print }
  ' "$SCAN_ROOT/.github/workflows/dependency-safety.yml" > "$SCAN_BLOCK"

  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = 'api graphql' ] || exit 97
printf '%s\n' "$@" >> "$SCAN_GH_ARGS"
if [ "${SCAN_FAIL_FIRST:-false}" = true ]; then
  for arg in "$@"; do [ "$arg" = name=first ] && exit 1; done
fi
cat "$SCAN_GHSA_FILE"
exit "${SCAN_GHSA_STATUS:-0}"
SH
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
endpoint=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://api.osv.dev/v1/query) endpoint=true ;;
    -d) shift; printf '%s\n' "$1" > "$SCAN_OSV_BODY" ;;
  esac
  shift
done
[ "$endpoint" = true ] || exit 97
cat "$SCAN_OSV_FILE"
exit "${SCAN_OSV_STATUS:-0}"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/curl"
  cat > "$SCAN_DRIVER" <<'SH'
set -euo pipefail
[ -s "$SCAN_BLOCK" ]
source "$SCAN_BLOCK"
DEPS=; SCAN_RESULTS=; FILTERED_RESULTS=; HAS_ERROR=
GHSA_TOTAL=0; OSV_TOTAL=0; FILTERED_TOTAL=0; SCAN_ERROR_COUNT=0
scan_dependency "$SCAN_ECO" "$SCAN_NAME" "$SCAN_VERSION"
if [ "${SCAN_SECOND:-false}" = true ]; then
  scan_dependency "$SCAN_ECO" second "$SCAN_VERSION"
fi
verdict=$(GUARD_TRIGGERED=false AGE_ERROR_COUNT=0 AGE_VIOLATION_COUNT=0 \
  SCAN_ERROR_COUNT="$SCAN_ERROR_COUNT" ADVISORY_COUNT="$((GHSA_TOTAL + OSV_TOTAL))" \
  RELEASE_AGE_POLICY=off MINIMUM_RELEASE_AGE_DAYS=5 AUTO_MERGE=true \
  bash "$SCAN_ROOT/scripts/safety-verdict.sh")
jq -n --arg deps "$DEPS" --arg rows "$SCAN_RESULTS" --arg filtered "$FILTERED_RESULTS" \
  --arg error "$HAS_ERROR" --arg verdict "$verdict" \
  --argjson ghsa "$GHSA_TOTAL" --argjson osv "$OSV_TOTAL" \
  --argjson filtered_count "$FILTERED_TOTAL" --argjson errors "$SCAN_ERROR_COUNT" \
  '{deps:$deps,rows:$rows,filtered:$filtered,error:$error,verdict:($verdict|split("\t")),
    ghsa:$ghsa,osv:$osv,filtered_count:$filtered_count,errors:$errors}'
SH
}

run_scan() {
  run env SCAN_ECO="$1" SCAN_NAME="$2" SCAN_VERSION="$3" \
    bash "$SCAN_DRIVER"
}

ghsa_advisory() {
  jq -n --arg patched "$1" '{data:{securityVulnerabilities:{nodes:[{
    advisory:{ghsaId:"GHSA-fixture",severity:"HIGH",summary:"fixture advisory"},
    firstPatchedVersion:(if $patched=="" then null else {identifier:$patched} end)
  }]}}}' > "$SCAN_GHSA_FILE"
}

@test "scanner maps each ecosystem and preserves version display" {
  local eco ghsa osv prefix
  while IFS='|' read -r eco ghsa osv prefix; do
    : > "$SCAN_GH_ARGS"
    run_scan "$eco" example 2.0.0
    [ "$status" -eq 0 ] || { echo "ecosystem=$eco: scanner failed: $output"; return 1; }
    printf '%s\n' "$output" | jq -e \
      '.ghsa==0 and .osv==0 and .errors==0 and .verdict[1]=="true"' >/dev/null || { echo "ecosystem=$eco: unexpected clean result"; return 1; }
    printf '%s\n' "$output" | jq -e --arg display "(${prefix}2.0.0)" \
      '.deps | contains($display)' >/dev/null || { echo "ecosystem=$eco: version display mismatch"; return 1; }
    grep -q "ecosystem: $ghsa" "$SCAN_GH_ARGS" || { echo "ecosystem=$eco: GHSA mapping mismatch"; return 1; }
    jq -e --arg eco "$osv" \
      '.package.name=="example" and .package.ecosystem==$eco and .version=="2.0.0"' \
      "$SCAN_OSV_BODY" >/dev/null || { echo "ecosystem=$eco: OSV mapping mismatch"; return 1; }
  done <<'CASES'
actions|ACTIONS|GitHub Actions|v
pypi|PIP|PyPI|v
npm|NPM|npm|
CASES
}

@test "missing versions query the whole package and report all GHSA rows" {
  local eco
  ghsa_advisory 1.0.0
  for eco in actions pypi npm; do
    run_scan "$eco" example ''
    [ "$status" -eq 0 ] || { echo "ecosystem=$eco: scanner failed: $output"; return 1; }
    printf '%s\n' "$output" | jq -e \
      '.ghsa==1 and .filtered_count==0 and .verdict[1]=="false"' >/dev/null || { echo "ecosystem=$eco: missing-version totals mismatch"; return 1; }
    jq -e 'has("version")|not' "$SCAN_OSV_BODY" >/dev/null || { echo "ecosystem=$eco: version was sent"; return 1; }
  done
}

@test "patched boundaries and missing patched versions retain their verdicts" {
  local eco patched expected
  for eco in actions pypi npm; do
    while IFS='|' read -r patched expected; do
      ghsa_advisory "$patched"
      run_scan "$eco" example 2.0.0
      [ "$status" -eq 0 ] || { echo "ecosystem=$eco patched=${patched:-none}: scanner failed: $output"; return 1; }
      printf '%s\n' "$output" | jq -e --argjson n "$expected" \
        '.filtered_count==$n and .ghsa==(1-$n)' >/dev/null || { echo "ecosystem=$eco patched=${patched:-none}: boundary mismatch"; return 1; }
    done <<'CASES'
1.0.0|1
2.0.0|1
3.0.0|0
|0
CASES
  done
}

@test "npm retains its distinct prefixed patched-version handling" {
  local eco expected
  ghsa_advisory v1.0.0
  for eco in actions pypi npm; do
    expected=1; [ "$eco" = npm ] && expected=0
    run_scan "$eco" example 2.0.0
    [ "$status" -eq 0 ] || { echo "ecosystem=$eco: scanner failed: $output"; return 1; }
    printf '%s\n' "$output" | jq -e --argjson n "$expected" \
      '.filtered_count==$n and .ghsa==(1-$n)' >/dev/null || { echo "ecosystem=$eco: prefix behavior mismatch"; return 1; }
  done
}

@test "OSV advisories reach report totals and suppress auto-merge" {
  printf '%s\n' '{"vulns":[{"id":"OSV-fixture","details":"detail fallback"}]}' > "$SCAN_OSV_FILE"
  run_scan npm example 2.0.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e \
    '.osv==1 and (.rows|contains("OSV-fixture")) and (.rows|contains("UNKNOWN"))
     and .verdict[1]=="false"' >/dev/null
}

@test "transport failures increment both counters and retain an error verdict" {
  export SCAN_GHSA_STATUS=1 SCAN_OSV_STATUS=1
  run_scan npm example 2.0.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e \
    '.errors==2 and .error=="true" and .verdict[0]=="error" and .verdict[1]=="false"
     and (.rows|contains("GHSA query failed")) and (.rows|contains("OSV query failed"))' >/dev/null
}

@test "GraphQL errors become scan errors rather than clean results" {
  printf '%s\n' '{"errors":[{"message":"fixture failure"}]}' > "$SCAN_GHSA_FILE"
  run_scan actions example 2.0.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e \
    '.errors==1 and .verdict[0]=="error" and (.rows|contains("fixture failure"))' >/dev/null
}

@test "a handled first dependency failure does not skip the next dependency" {
  export SCAN_FAIL_FIRST=true SCAN_SECOND=true
  run_scan pypi first 2.0.0
  [ "$status" -eq 0 ]
  grep -qx name=second "$SCAN_GH_ARGS"
  printf '%s\n' "$output" | jq -e \
    '.errors==1 and (.deps|contains("second")) and .verdict[0]=="error"' >/dev/null
}

@test "all three workflow callers invoke the shared scanner directly" {
  local expected
  for expected in \
    'scan_dependency actions "$ACTION" "${ACTION_VERSIONS[$ACTION]}"' \
    'scan_dependency pypi "$PKG" "${PY_VERSIONS[$PKG]}"' \
    'scan_dependency npm "$PKG" "$_npm_ver"'; do
    grep -qF "$expected" "$SCAN_ROOT/.github/workflows/dependency-safety.yml" || return 1
  done
}

@test "multiple GHSA and OSV rows accumulate in the shared report" {
  ghsa_advisory ''
  jq '.data.securityVulnerabilities.nodes += .data.securityVulnerabilities.nodes' \
    "$SCAN_GHSA_FILE" > "$BATS_TEST_TMPDIR/two.json"
  mv "$BATS_TEST_TMPDIR/two.json" "$SCAN_GHSA_FILE"
  printf '%s\n' '{"vulns":[{"id":"OSV-one","summary":"one"},{"id":"OSV-two","summary":"two"}]}' > "$SCAN_OSV_FILE"
  run_scan npm example 2.0.0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e \
    '.ghsa==2 and .osv==2 and (.rows|contains("OSV-two")) and .verdict[1]=="false"' >/dev/null
}

@test "missing GHSA nodes preserve existing empty-result behavior" {
  local eco version
  printf '%s\n' '{"data":{"securityVulnerabilities":{}}}' > "$SCAN_GHSA_FILE"
  for eco in actions pypi npm; do
    for version in '' 2.0.0; do
      run_scan "$eco" example "$version"
      [ "$status" -eq 0 ] || { echo "ecosystem=$eco version=${version:-none}: scanner failed: $output"; return 1; }
      printf '%s\n' "$output" | jq -e '.ghsa==0 and .errors==0' >/dev/null || { echo "ecosystem=$eco version=${version:-none}: empty-nodes mismatch"; return 1; }
    done
  done
}

@test "package names remain escaped data in OSV requests" {
  local package='@scope/pkg"quoted'
  run_scan npm "$package" 2.0.0
  [ "$status" -eq 0 ]
  jq -e --arg name "$package" '.package.name==$name' "$SCAN_OSV_BODY" >/dev/null
}
