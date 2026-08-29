bats_require_minimum_version 1.5.0
#!/usr/bin/env bats
# assert-packed-manifest.bats — coverage for the sealed-tarball guard used by
# publish-npm.yml before artifact upload.
#
# Fixtures are readable directories under tests/fixtures/assert-packed-manifest/
# that this file tars at test time. Committing .tgz blobs instead would make
# the interesting content — the manifest — invisible in a diff.
#
# --separate-stderr throughout: plain `run` folds stderr into $output, so a
# diagnostic that leaked onto stdout would be invisible to these assertions.
# Every non-zero-exit test asserts stdout stays empty.

SCRIPT="scripts/assert-packed-manifest.sh"
FIXTURES="tests/fixtures/assert-packed-manifest"
NAME="@probe/clean"
VERSION="1.0.0"

setup() {
  REPO_ROOT="$PWD"
  TEST_TMP=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_TMP"
}

tarball_for() {
  local case_name="$1"
  local out="$TEST_TMP/${case_name}.tgz"
  ( cd "$REPO_ROOT/$FIXTURES/$case_name" && tar -czf "$out" package )
  printf '%s' "$out"
}

# --- identity --------------------------------------------------------------

@test "matching name and version pass" {
  tgz="$(tarball_for clean)"
  run --separate-stderr "$SCRIPT" "$tgz" "$NAME" "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "${tgz} is ${NAME}@${VERSION} with no unpublishable dependency specifiers." ]
  [ -z "$stderr" ]
}

@test "a lifecycle script that renamed the package is caught" {
  run --separate-stderr "$SCRIPT" "$(tarball_for renamed-by-lifecycle)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"@probe/something-else"* ]] || return 1
  [[ "$stderr" == *"does not match the requested package"* ]] || return 1
  [ -z "$output" ]
}

@test "a lifecycle script that changed the version is caught" {
  run --separate-stderr "$SCRIPT" "$(tarball_for reversioned-by-lifecycle)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"9.9.9"* ]] || return 1
  [[ "$stderr" == *"refusing to publish"* ]] || return 1
  [ -z "$output" ]
}

@test "missing expected-name or expected-version is malformed input" {
  run --separate-stderr "$SCRIPT" "$(tarball_for clean)"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage:"* ]] || return 1
  [ -z "$output" ]
}

# --- protocols -------------------------------------------------------------

@test "registry-resolvable specifiers pass" {
  tgz="$(tarball_for clean)"
  run --separate-stderr "$SCRIPT" "$tgz" "$NAME" "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "${tgz} is ${NAME}@${VERSION} with no unpublishable dependency specifiers." ]
  [ -z "$stderr" ]
}

@test "every allowed protocol passes" {
  tgz="$(tarball_for allowed-protocols)"
  run --separate-stderr "$SCRIPT" "$tgz" "$NAME" "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "${tgz} is ${NAME}@${VERSION} with no unpublishable dependency specifiers." ]
  [ -z "$stderr" ]
}

@test "github shortcut with an embedded semver fragment is not misparsed" {
  tgz="$(tarball_for allowed-protocols)"
  run --separate-stderr "$SCRIPT" "$tgz" "$NAME" "$VERSION"
  [ "$status" -eq 0 ]
  # A bare exit-0 with empty stderr already proves 'semver:' inside the
  # github: fragment was never treated as its own violating protocol.
  [ "$output" = "${tgz} is ${NAME}@${VERSION} with no unpublishable dependency specifiers." ]
  [ -z "$stderr" ]
}

@test "workspace: in dependencies is rejected with pnpm remediation" {
  run --separate-stderr "$SCRIPT" "$(tarball_for workspace-dep)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"dependencies.@probe/core"* ]] || return 1
  [[ "$stderr" == *"workspace:^"* ]] || return 1
  [[ "$stderr" == *"pnpm pack --json"* ]] || return 1
  [[ "$stderr" == *"frozen install"* ]] || return 1
  [ -z "$output" ]
}

@test "catalog: is rejected and does not demand a frozen install" {
  run --separate-stderr "$SCRIPT" "$(tarball_for catalog-dep)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"pnpm pack --json"* ]] || return 1
  ! printf '%s\n' "$stderr" | grep -q 'frozen install' || return 1
  [ -z "$output" ]
}

@test "link: in optionalDependencies is rejected as a local path" {
  run --separate-stderr "$SCRIPT" "$(tarball_for link-optional)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"optionalDependencies.@probe/core"* ]] || return 1
  [[ "$stderr" == *"local path cannot be published"* ]] || return 1
  [ -z "$output" ]
}

@test "file: in peerDependencies is rejected as a local path" {
  run --separate-stderr "$SCRIPT" "$(tarball_for file-peer)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"peerDependencies.@probe/core"* ]] || return 1
  [[ "$stderr" == *"local path cannot be published"* ]] || return 1
  [ -z "$output" ]
}

@test "bare relative and absolute paths are rejected as local paths" {
  run --separate-stderr "$SCRIPT" "$(tarball_for bare-path-dep)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  # npm-package-arg resolves each of these to a local directory with no
  # protocol prefix, so '../core' means exactly what 'file:../core' means.
  [[ "$stderr" == *"dependencies.@probe/core"* ]] || return 1
  [[ "$stderr" == *"dependencies.sib"* ]] || return 1
  [[ "$stderr" == *"optionalDependencies.home"* ]] || return 1
  [[ "$stderr" == *"peerDependencies.abs"* ]] || return 1
  [[ "$stderr" == *"local path cannot be published"* ]] || return 1
  [[ "$stderr" == *"4 unpublishable"* ]] || return 1
  [ -z "$output" ]
}

@test "a leading space does not let a specifier slip past the protocol anchor" {
  run --separate-stderr "$SCRIPT" "$(tarball_for leading-space-workspace)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"dependencies.@probe/core"* ]] || return 1
  [[ "$stderr" == *"pnpm pack --json"* ]] || return 1
  [[ "$stderr" == *"1 unpublishable"* ]] || return 1
  [ -z "$output" ]
}

@test "jq-escaped leading control whitespace does not hide bare local paths" {
  run --separate-stderr "$SCRIPT" "$(tarball_for leading-control-paths)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"dependencies.tab-core"* ]] || return 1
  [[ "$stderr" == *"optionalDependencies.newline-core"* ]] || return 1
  [[ "$stderr" == *"local path cannot be published"* ]] || return 1
  [[ "$stderr" == *"2 unpublishable"* ]] || return 1
  [ -z "$output" ]
}

@test "a bare range, a dist-tag and '*' survive the local-path fallback" {
  # The regression the local-path fallback could plausibly introduce: a
  # colon-less specifier that is NOT a path must still reach `continue`.
  tgz="$(tarball_for clean)"
  run --separate-stderr "$SCRIPT" "$tgz" "$NAME" "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "${tgz} is ${NAME}@${VERSION} with no unpublishable dependency specifiers." ]
  [ -z "$stderr" ]
}

@test "devDependencies are ignored" {
  tgz="$(tarball_for dev-only)"
  run --separate-stderr "$SCRIPT" "$tgz" "$NAME" "$VERSION"
  [ "$status" -eq 0 ]
  [ "$output" = "${tgz} is ${NAME}@${VERSION} with no unpublishable dependency specifiers." ]
  [ -z "$stderr" ]
}

@test "an unrecognized protocol is rejected with the generic hint" {
  run --separate-stderr "$SCRIPT" "$(tarball_for unknown-protocol)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"quantum:"* ]] || return 1
  [[ "$stderr" == *"open an issue"* ]] || return 1
  [ -z "$output" ]
}

@test "all violations are reported in one run, not just the first" {
  run --separate-stderr "$SCRIPT" "$(tarball_for multi-violation)" "$NAME" "$VERSION"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"dependencies.a"* ]] || return 1
  [[ "$stderr" == *"dependencies.b"* ]] || return 1
  [[ "$stderr" == *"optionalDependencies.c"* ]] || return 1
  [[ "$stderr" == *"peerDependencies.d"* ]] || return 1
  [[ "$stderr" == *"4 unpublishable"* ]] || return 1
  [ -z "$output" ]
}

# --- malformed input -------------------------------------------------------

@test "a tarball without package/package.json is malformed input" {
  mkdir -p "$TEST_TMP/other/notpackage"
  printf 'x' > "$TEST_TMP/other/notpackage/file.txt"
  ( cd "$TEST_TMP/other" && tar -czf "$TEST_TMP/bad.tgz" notpackage )
  run --separate-stderr "$SCRIPT" "$TEST_TMP/bad.tgz" "$NAME" "$VERSION"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no package/package.json"* ]] || return 1
  [ -z "$output" ]
}

@test "a missing tarball is malformed input" {
  run --separate-stderr "$SCRIPT" "$TEST_TMP/absent.tgz" "$NAME" "$VERSION"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not found"* ]] || return 1
  [ -z "$output" ]
}
