#!/usr/bin/env bats

SCRIPT="scripts/packagemanager-bump.sh"

@test "missing --mode exits 2" {
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--mode"* ]] || return 1
}

@test "repeated --mode exits 2" {
  run bash "$SCRIPT" --mode=current --mode=rewrite </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"repeated"* ]] || return 1
}

@test "unknown argument exits 2" {
  run bash "$SCRIPT" --mode=current --frobnicate </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"frobnicate"* ]] || return 1
}

@test "unknown mode value exits 2" {
  run bash "$SCRIPT" --mode=teleport </dev/null
  [ "$status" -eq 2 ]
  # "*teleport*" alone does not discriminate: the catch-all's "unknown
  # argument: --mode=teleport" message also contains "teleport" as a
  # substring. Assert on "unknown mode" so a mutation that deletes the
  # --mode=* guard (and falls through to the catch-all) is caught.
  [[ "$output" == *"unknown mode"* ]] || return 1
}
