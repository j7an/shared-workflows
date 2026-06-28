#!/usr/bin/env bats
# derive-published-version.bats - tests for scripts/derive-published-version.sh

SCRIPT="$BATS_TEST_DIRNAME/../scripts/derive-published-version.sh"

setup() {
  TMPDIR=$(mktemp -d)
  DIST="$TMPDIR/dist"
  mkdir -p "$DIST"
}

teardown() {
  rm -rf "$TMPDIR"
}

make_artifacts() {
  local version="$1"
  touch "$DIST/example_pkg-${version}-py3-none-any.whl"
  touch "$DIST/example_pkg-${version}.tar.gz"
}

run_deriver() {
  run bash "$SCRIPT" "$DIST" "$1"
}

@test "one wheel and one sdist extracts the normalized version" {
  make_artifacts "1.2.3"
  run_deriver "v1.2.3"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
}

@test "version extraction uses wheel field two and tolerates a wheel build tag" {
  touch "$DIST/example_pkg-1.2.3-1-py3-none-any.whl"
  touch "$DIST/example_pkg-1.2.3.tar.gz"
  run_deriver "v1.2.3"
  [ "$status" -eq 0 ]
  [ "$output" = "1.2.3" ]
}

@test "path-prefixed tags strip to the canonical version tail" {
  make_artifacts "0.1.0"
  run_deriver "tools/v0.1.0"
  [ "$status" -eq 0 ]
  [ "$output" = "0.1.0" ]
}

@test "no wheel fails loudly" {
  touch "$DIST/example_pkg-1.2.3.tar.gz"
  run_deriver "v1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exactly one wheel"* ]]
}

@test "multiple wheels fail loudly" {
  touch "$DIST/example_pkg-1.2.3-py3-none-any.whl"
  touch "$DIST/example_pkg-1.2.3-1-py3-none-any.whl"
  touch "$DIST/example_pkg-1.2.3.tar.gz"
  run_deriver "v1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exactly one wheel"* ]]
}

@test "no sdist fails loudly" {
  touch "$DIST/example_pkg-1.2.3-py3-none-any.whl"
  run_deriver "v1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exactly one sdist"* ]]
}

@test "multiple sdists fail loudly" {
  touch "$DIST/example_pkg-1.2.3-py3-none-any.whl"
  touch "$DIST/example_pkg-1.2.3.tar.gz"
  touch "$DIST/example_pkg-1.2.3.post1.tar.gz"
  run_deriver "v1.2.3"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected exactly one sdist"* ]]
}

@test "tag and artifact version mismatch fails before publishing" {
  make_artifacts "1.2.3"
  run_deriver "v1.2.4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tag tail '1.2.4' does not equal built version '1.2.3'"* ]]
  [[ "$output" == *"v1.2.3"* ]]
}

@test "hyphenated prerelease tag fails with canonical spelling guidance" {
  make_artifacts "1.2.3rc1"
  run_deriver "v1.2.3-rc1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tag tail '1.2.3-rc1' does not equal built version '1.2.3rc1'"* ]]
  [[ "$output" == *"v1.2.3rc1"* ]]
}

@test "requires dist directory and tag arguments" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]

  run bash "$SCRIPT" "$DIST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
