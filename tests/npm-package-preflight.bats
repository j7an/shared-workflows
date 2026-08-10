bats_require_minimum_version 1.5.0
#!/usr/bin/env bats
# npm-package-preflight.bats — behavioral coverage for the package selector
# used by publish-npm.yml's build job.

SCRIPT="scripts/npm-package-preflight.sh"

setup() {
  TEST_TMP=$(mktemp -d)
  export GITHUB_WORKSPACE="$TEST_TMP/ws"
  OUTSIDE="$TEST_TMP/outside"

  mkdir -p "$GITHUB_WORKSPACE/packages/perms" "$GITHUB_WORKSPACE/empty" "$OUTSIDE"

  cat > "$GITHUB_WORKSPACE/package.json" <<'JSON'
{ "name": "root", "private": true }
JSON

  cat > "$GITHUB_WORKSPACE/packages/perms/package.json" <<'JSON'
{ "name": "@probe/perms", "version": "0.1.0" }
JSON

  cat > "$OUTSIDE/package.json" <<'JSON'
{ "name": "@probe/outside", "version": "9.9.9" }
JSON
  ln -s "$OUTSIDE" "$GITHUB_WORKSPACE/escape"

  ROOTREPO="$TEST_TMP/rootrepo"
  mkdir -p "$ROOTREPO"
  cat > "$ROOTREPO/package.json" <<'JSON'
{ "name": "solo", "version": "1.2.3" }
JSON
}

teardown() {
  rm -rf "$TEST_TMP"
}

# --separate-stderr throughout this file: plain `run` folds stderr into
# $output, so a diagnostic that leaked onto stdout - the exact failure the
# control-character guard exists to prevent - would be invisible to these
# assertions. Task 3 pipes this script's stdout straight into
# $GITHUB_OUTPUT, so stdout purity on every non-zero exit is load-bearing,
# not cosmetic.

@test "nested package resolves and emits dir and version" {
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms v0.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "dir=packages/perms
version=0.1.0" ]
  [ -z "$stderr" ]
}

@test "root package with default dir keeps working" {
  GITHUB_WORKSPACE="$ROOTREPO" run --separate-stderr "$SCRIPT" . solo v1.2.3
  [ "$status" -eq 0 ]
  [ "$output" = "dir=.
version=1.2.3" ]
}

@test "empty package-dir normalizes to the repository root" {
  GITHUB_WORKSPACE="$ROOTREPO" run --separate-stderr "$SCRIPT" "" solo v1.2.3
  [ "$status" -eq 0 ]
  [ "$output" = "dir=.
version=1.2.3" ]
}

@test "trailing slashes are stripped" {
  run --separate-stderr "$SCRIPT" packages/perms/// @probe/perms v0.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "dir=packages/perms
version=0.1.0" ]
}

@test "prefixed tag yields the trailing semver" {
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms permissions/v0.1.0
  [ "$status" -eq 0 ]
  [ "$output" = "dir=packages/perms
version=0.1.0" ]
}

@test "prerelease tag is parsed" {
  cat > "$GITHUB_WORKSPACE/packages/perms/package.json" <<'JSON'
{ "name": "@probe/perms", "version": "0.1.0-rc.1" }
JSON
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms v0.1.0-rc.1
  [ "$status" -eq 0 ]
  [ "$output" = "dir=packages/perms
version=0.1.0-rc.1" ]
}

# --- control characters: $GITHUB_OUTPUT record injection -------------------

@test "package-dir containing a newline is rejected" {
  run --separate-stderr "$SCRIPT" "$(printf 'packages/perms\nversion=9.9.9')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]] || return 1
  # The injection this exists to stop must not appear anywhere on stdout.
  [ -z "$output" ]
}

@test "package-dir containing a carriage return is rejected" {
  run --separate-stderr "$SCRIPT" "$(printf 'packages/perms\rx')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]] || return 1
  [ -z "$output" ]
}

@test "package-dir containing a tab is rejected" {
  run --separate-stderr "$SCRIPT" "$(printf 'packages/\tperms')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]] || return 1
  [ -z "$output" ]
}

@test "package-dir containing a non-printing control byte is rejected" {
  run --separate-stderr "$SCRIPT" "$(printf 'packages/\001perms')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]] || return 1
  [ -z "$output" ]
}

@test "a rejected package-dir emits no dir= line at all" {
  run --separate-stderr "$SCRIPT" "$(printf 'packages/perms\nversion=9.9.9')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  ! printf '%s\n' "$output" | grep -q '^dir=' || return 1
}

# --- path safety -----------------------------------------------------------

@test "absolute package-dir is rejected as malformed input" {
  run --separate-stderr "$SCRIPT" /etc @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"absolute"* ]] || return 1
  [ -z "$output" ]
}

@test "traversal through .. is rejected" {
  run --separate-stderr "$SCRIPT" ../outside @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  # Assert the discriminating fragment, not a bare "..": the message also
  # echoes back the raw input '../outside', which itself contains ".." and
  # would make a bare substring match pass for the wrong reason.
  [[ "$stderr" == *"'..' path segment"* ]] || return 1
  [ -z "$output" ]
}

@test "'..' that resolves back inside is still rejected" {
  run --separate-stderr "$SCRIPT" packages/../packages/perms @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"'..' path segment"* ]] || return 1
  [ -z "$output" ]
}

@test "symlink escaping the checkout is rejected" {
  run --separate-stderr "$SCRIPT" escape @probe/outside v9.9.9
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"outside the checkout"* ]] || return 1
  [ -z "$output" ]
}

@test "nonexistent package-dir is rejected" {
  run --separate-stderr "$SCRIPT" packages/nope @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"does not exist"* ]] || return 1
  [ -z "$output" ]
}

@test "directory without package.json is rejected" {
  run --separate-stderr "$SCRIPT" empty @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no package.json"* ]] || return 1
  [ -z "$output" ]
}

@test "malformed package.json is rejected" {
  printf '{ not json' > "$GITHUB_WORKSPACE/packages/perms/package.json"
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not valid JSON"* ]] || return 1
  [ -z "$output" ]
}

# --- validation order: malformed input beats policy verdicts ---------------
#
# Exit 2 (malformed/unsafe input) must win over exit 1 (policy verdict) when
# both are independently true. A caller misconfiguration - here, a
# control-character package-dir - must never be reported as "this package
# is not publishable", which is what an unparseable tag alone would report.

@test "a control character in package-dir wins over an unparseable tag" {
  run --separate-stderr "$SCRIPT" "$(printf 'packages/\001perms')" @probe/perms release-candidate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"control character"* ]] || return 1
  [[ "$stderr" != *"Could not parse semver"* ]] || return 1
  [ -z "$output" ]
}

# --- manifest policy -------------------------------------------------------

@test "private manifest fails policy" {
  cat > "$GITHUB_WORKSPACE/packages/perms/package.json" <<'JSON'
{ "name": "@probe/perms", "version": "0.1.0", "private": true }
JSON
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms v0.1.0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"private"* ]] || return 1
  [ -z "$output" ]
}

@test "name mismatch fails policy" {
  run --separate-stderr "$SCRIPT" packages/perms @probe/other v0.1.0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"@probe/other"* ]] || return 1
  [ -z "$output" ]
}

@test "version mismatch fails policy" {
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms v0.2.0
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"refusing to publish"* ]] || return 1
  [ -z "$output" ]
}

@test "unparseable tag fails policy" {
  run --separate-stderr "$SCRIPT" packages/perms @probe/perms release-candidate
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Could not parse semver"* ]] || return 1
  [ -z "$output" ]
}

@test "missing arguments are rejected" {
  run --separate-stderr "$SCRIPT" packages/perms
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage:"* ]] || return 1
  [ -z "$output" ]
}
