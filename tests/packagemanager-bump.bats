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

PFX=tests/fixtures/packagemanager-bump/packuments

# Fixed clock: 2025-04-01T00:00:00Z. Every fixture timestamp above predates it,
# so soak outcomes are decided by --min-age-days alone and never by wall time.
CLOCK=1743465600

sel() { # $1 = packument fixture, $2 = current version, $3 = min-age-days
  run bash "$SCRIPT" --mode=select \
    --current="$2" --now="$CLOCK" --min-age-days="$3" < "$PFX/$1"
}

@test "select: picks the newest soaked version in the major" {
  sel basic.json 9.15.0 5
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '9.15.9\tnormal')" ]
}

@test "select: already newest reports major-available, not current" {
  # basic.json holds 10.1.0, so the honest reason is that a newer MAJOR exists.
  # bats folds stderr into $output, which is where reason codes go.
  sel basic.json 9.15.9 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"major-available"* ]] || return 1
}

@test "select: never crosses a major" {
  sel basic.json 9.15.9 5
  [ "$status" -eq 0 ]
  [[ "$output" != *"10.1.0"* ]] || return 1
}

@test "select: prereleases are excluded from selection" {
  sel basic.json 9.15.9 5
  [ "$status" -eq 0 ]
  [[ "$output" != *"rc"* ]] || return 1
}

@test "select: nothing soaked reports cooldown" {
  sel basic.json 9.15.0 99999
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooldown"* ]] || return 1
}

@test "select: cooldown and major-available are distinguishable" {
  # The whole point of reason codes: two different zero-selection outcomes
  # that a bare "nothing selected" assertion would conflate.
  sel basic.json 9.15.0 99999
  [[ "$output" == *"cooldown"* ]] || return 1
  sel basic.json 9.15.9 5
  [[ "$output" == *"major-available"* ]] || return 1
}

@test "select: a candidate missing its .time entry fails closed" {
  # Not a silent drop — a malformed packument must not read as a clean cooldown.
  sel missing-one-time.json 9.15.0 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"malformed-packument"* ]] || return 1
}

@test "select: deprecated versions are skipped, older good one wins" {
  sel newest-deprecated.json 9.15.0 5
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '9.15.7\tnormal')" ]
}

@test "select: unknown major fails rather than reporting nothing to do" {
  sel other-major-only.json 9.15.0 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"no published"* ]] || return 1
}

@test "select: packument without .time fails closed" {
  sel no-time.json 9.15.0 5
  [ "$status" -eq 2 ]
}

@test "select: invalid packument JSON fails closed" {
  run bash "$SCRIPT" --mode=select --current=9.15.0 --now="$CLOCK" --min-age-days=5 <<< 'nope'
  [ "$status" -eq 2 ]
}

@test "select: missing --current fails" {
  run bash "$SCRIPT" --mode=select --now="$CLOCK" --min-age-days=5 < "$PFX/basic.json"
  [ "$status" -eq 2 ]
}

@test "select: non-numeric --now fails" {
  run bash "$SCRIPT" --mode=select --current=9.15.0 --now=soon --min-age-days=5 < "$PFX/basic.json"
  [ "$status" -eq 2 ]
}

@test "select: prerelease-only when no newer major exists" {
  # prerelease-no-major.json has a newer prerelease in the pinned major but
  # no stable release in any higher major, so major-available cannot fire
  # and this is the only fixture that reaches the prerelease-only branch.
  sel prerelease-no-major.json 9.15.9 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"prerelease-only"* ]] || return 1
}

@test "select: truly nothing to do reports current" {
  # only-current.json holds nothing but the pinned version itself: no newer
  # stable in-major release, no prerelease, no higher major. This is the
  # only fixture that reaches the terminal "current" branch rather than
  # cooldown/major-available/prerelease-only.
  sel only-current.json 9.15.9 5
  [ "$status" -eq 0 ]
  [ "$output" = "current" ]
}

@test "select: missing --now fails" {
  run bash "$SCRIPT" --mode=select --current=9.15.0 --min-age-days=5 < "$PFX/basic.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires --now"* ]] || return 1
}

@test "select: missing --min-age-days fails" {
  run bash "$SCRIPT" --mode=select --current=9.15.0 --now="$CLOCK" < "$PFX/basic.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"requires --min-age-days"* ]] || return 1
}

@test "select: malformed --current fails" {
  sel basic.json 9.15 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"not x.y.z"* ]] || return 1
}

@test "select: non-numeric --min-age-days fails" {
  run bash "$SCRIPT" --mode=select --current=9.15.0 --now="$CLOCK" --min-age-days=soon < "$PFX/basic.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a number"* ]] || return 1
}

@test "select: unparseable candidate timestamp fails closed" {
  # Distinct from the missing-.time-entry guard: this candidate HAS a .time
  # entry, but it is not a parseable ISO8601 timestamp.
  sel bad-timestamp.json 9.15.0 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"unparseable timestamp"* ]] || return 1
}

@test "select: deprecated pin bypasses cooldown and takes the un-soaked version" {
  sel pin-deprecated.json 9.15.0 5
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '9.15.2\tbypass')" ]
}

@test "select: a healthy pin does NOT reach the un-soaked version" {
  # Same fixture, same clock, same threshold, and an un-soaked candidate
  # (9.15.2) is present in BOTH runs — the only difference is that this pin
  # is not deprecated. That is what makes this a real contrast.
  sel pin-deprecated.json 9.15.1 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooldown"* ]] || return 1
}

@test "select: deprecated pin with no escape exits 3" {
  sel pin-deprecated-no-escape.json 9.15.0 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"deprecated"* ]] || return 1
}

@test "select: exit 3 quotes the registry deprecation message verbatim" {
  sel pin-deprecated-no-escape.json 9.15.0 5
  [ "$status" -eq 3 ]
  [[ "$output" == *"Upgrade to pnpm 10."* ]] || return 1
}
