#!/usr/bin/env bats
# classify-prerelease.bats - tests for scripts/classify-prerelease.sh

SCRIPT="$BATS_TEST_DIRNAME/../scripts/classify-prerelease.sh"

run_classifier() {
  run bash "$SCRIPT" "$1"
}

@test "classifies normalized pre-release spellings as prerelease" {
  for version in 1.0a1 1.0b2 1.0rc1; do
    run_classifier "$version"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "classifies dev releases as prerelease" {
  for version in 1.0.dev1 1.0.post1.dev2; do
    run_classifier "$version"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "classifies stable, post, epoch, and multi-segment releases as stable" {
  for version in 1.0.post1 '1!2.0' 1.2.3 1.2.3.4; do
    run_classifier "$version"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
  done
}

@test "rejects local versions as unsupported input" {
  run_classifier "1.2.3+b1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"local versions"* ]]
}

@test "requires exactly one version argument" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]

  run bash "$SCRIPT" "1.2.3" "1.2.4"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
