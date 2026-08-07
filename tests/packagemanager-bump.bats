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

MFX=tests/fixtures/packagemanager-bump/manifests

@test "current: plain pnpm pin" {
  run bash "$SCRIPT" --mode=current < "$MFX/plain.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pnpm\t9.15.0\t9\t')" ]
}

@test "current: hashed pin splits version from suffix" {
  run bash "$SCRIPT" --mode=current < "$MFX/hashed.json"
  [ "$status" -eq 0 ]
  [[ "$output" == "$(printf 'pnpm\t9.15.0\t9\t')+sha224."* ]] || return 1
}

@test "current: minified manifest parses" {
  run bash "$SCRIPT" --mode=current < "$MFX/minified.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'pnpm\t9.15.0\t9\t')" ]
}

@test "current: tab-indented manifest parses" {
  run bash "$SCRIPT" --mode=current < "$MFX/tabs.json"
  [ "$status" -eq 0 ]
}

@test "current: npm packageManager is out of scope" {
  run bash "$SCRIPT" --mode=current < "$MFX/npm-pm.json"
  [ "$status" -eq 2 ]
  # "npm" alone does not discriminate: it's also a substring of the
  # not-exact fallback message ("...not an exact x.y.z: npm@10.8.2"),
  # so a mutation that drops the not-pnpm guard would still pass this
  # assertion. Match "not pnpm" instead, which only that branch emits.
  [[ "$output" == *"not pnpm"* ]] || return 1
}

@test "current: yarn packageManager is out of scope" {
  run bash "$SCRIPT" --mode=current < "$MFX/yarn-pm.json"
  [ "$status" -eq 2 ]
  # Discriminate the not-pnpm reason code from no-pin/not-exact.
  [[ "$output" == *"not pnpm"* ]] || return 1
}

@test "current: absent field fails" {
  run bash "$SCRIPT" --mode=current < "$MFX/absent.json"
  [ "$status" -eq 2 ]
  # Full phrase from the jq-failure branch specifically (not just the
  # "no top-level packageManager field" fallback's shared words) so a
  # mutation that deletes this branch and falls through to the fallback
  # is still caught.
  [[ "$output" == *"not valid JSON, or has no top-level packageManager"* ]] || return 1
}

@test "current: empty packageManager string fails" {
  run bash "$SCRIPT" --mode=current < "$MFX/empty-pm.json"
  [ "$status" -eq 2 ]
  # This is the only fixture that reaches the second, fallback guard
  # ([ -n "$raw" ]): jq -e treats "" as neither null nor false, so it
  # exits 0 with empty output, skipping the first die entirely.
  [[ "$output" == *"no top-level packageManager field"* ]] || return 1
}

@test "current: range instead of exact version fails" {
  run bash "$SCRIPT" --mode=current < "$MFX/range.json"
  [ "$status" -eq 2 ]
  # Discriminate the not-exact reason code from no-pin/not-pnpm.
  [[ "$output" == *"not an exact"* ]] || return 1
}

@test "current: nested packageManager key does not match" {
  run bash "$SCRIPT" --mode=current < "$MFX/nested-decoy.json"
  [ "$status" -eq 2 ]
  # A top-level-only lookup treats this the same as a missing field
  # (no-pin), not as a parse failure or wrong-tool failure.
  [[ "$output" == *"not valid JSON, or has no top-level packageManager"* ]] || return 1
}

@test "current: invalid JSON fails" {
  run bash "$SCRIPT" --mode=current <<< 'not json'
  [ "$status" -eq 2 ]
  # Same no-pin diagnostic branch as absent/nested-decoy (jq -e fails the
  # same way for a parse error as for a missing top-level field).
  [[ "$output" == *"not valid JSON, or has no top-level packageManager"* ]] || return 1
}
