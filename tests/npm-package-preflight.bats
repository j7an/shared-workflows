#!/usr/bin/env bats
# npm-package-preflight.bats — behavioral coverage for the package selector
# used by publish-npm.yml's build job.

SCRIPT="scripts/npm-package-preflight.sh"

setup() {
  REPO_ROOT="$PWD"
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

@test "nested package resolves and emits dir and version" {
  run "$SCRIPT" packages/perms @probe/perms v0.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"dir=packages/perms"* ]]
  [[ "$output" == *"version=0.1.0"* ]]
}

@test "root package with default dir keeps working" {
  GITHUB_WORKSPACE="$TEST_TMP/rootrepo" run "$SCRIPT" . solo v1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"dir=."* ]]
  [[ "$output" == *"version=1.2.3"* ]]
}

@test "empty package-dir normalizes to the repository root" {
  GITHUB_WORKSPACE="$TEST_TMP/rootrepo" run "$SCRIPT" "" solo v1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"dir=."* ]]
}

@test "trailing slashes are stripped" {
  run "$SCRIPT" packages/perms/// @probe/perms v0.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"dir=packages/perms"* ]]
}

@test "prefixed tag yields the trailing semver" {
  run "$SCRIPT" packages/perms @probe/perms permissions/v0.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"version=0.1.0"* ]]
}

@test "prerelease tag is parsed" {
  cat > "$GITHUB_WORKSPACE/packages/perms/package.json" <<'JSON'
{ "name": "@probe/perms", "version": "0.1.0-rc.1" }
JSON
  run "$SCRIPT" packages/perms @probe/perms v0.1.0-rc.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"version=0.1.0-rc.1"* ]]
}

# --- control characters: $GITHUB_OUTPUT record injection -------------------

@test "package-dir containing a newline is rejected" {
  run "$SCRIPT" "$(printf 'packages/perms\nversion=9.9.9')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"control character"* ]]
  # The injection this exists to stop must not appear anywhere in the output.
  ! printf '%s\n' "$output" | grep -q 'version=9.9.9' || return 1
}

@test "package-dir containing a carriage return is rejected" {
  run "$SCRIPT" "$(printf 'packages/perms\rx')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"control character"* ]]
}

@test "package-dir containing a tab is rejected" {
  run "$SCRIPT" "$(printf 'packages/\tperms')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"control character"* ]]
}

@test "package-dir containing a non-printing control byte is rejected" {
  run "$SCRIPT" "$(printf 'packages/\001perms')" @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"control character"* ]]
}

@test "a rejected package-dir emits no dir= line at all" {
  run "$SCRIPT" "$(printf 'packages/perms\nversion=9.9.9')" @probe/perms v0.1.0
  ! printf '%s\n' "$output" | grep -q '^dir=' || return 1
}

# --- path safety -----------------------------------------------------------

@test "absolute package-dir is rejected as malformed input" {
  run "$SCRIPT" /etc @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"absolute"* ]]
}

@test "traversal through .. is rejected" {
  run "$SCRIPT" ../outside @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *".."* ]]
}

@test "'..' that resolves back inside is still rejected" {
  run "$SCRIPT" packages/../packages/perms @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *".."* ]]
}

@test "symlink escaping the checkout is rejected" {
  run "$SCRIPT" escape @probe/outside v9.9.9
  [ "$status" -eq 2 ]
  [[ "$output" == *"outside the checkout"* ]]
}

@test "nonexistent package-dir is rejected" {
  run "$SCRIPT" packages/nope @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "directory without package.json is rejected" {
  run "$SCRIPT" empty @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"no package.json"* ]]
}

@test "malformed package.json is rejected" {
  printf '{ not json' > "$GITHUB_WORKSPACE/packages/perms/package.json"
  run "$SCRIPT" packages/perms @probe/perms v0.1.0
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid JSON"* ]]
}

# --- manifest policy -------------------------------------------------------

@test "private manifest fails policy" {
  cat > "$GITHUB_WORKSPACE/packages/perms/package.json" <<'JSON'
{ "name": "@probe/perms", "version": "0.1.0", "private": true }
JSON
  run "$SCRIPT" packages/perms @probe/perms v0.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"private"* ]]
}

@test "name mismatch fails policy" {
  run "$SCRIPT" packages/perms @probe/other v0.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"@probe/other"* ]]
}

@test "version mismatch fails policy" {
  run "$SCRIPT" packages/perms @probe/perms v0.2.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to publish"* ]]
}

@test "unparseable tag fails policy" {
  run "$SCRIPT" packages/perms @probe/perms release-candidate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not parse semver"* ]]
}

@test "missing arguments are rejected" {
  run "$SCRIPT" packages/perms
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
