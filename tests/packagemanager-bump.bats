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

# Redirects stdout to a file; $output would strip the trailing newline.
rw() { # $1 = manifest fixture, $2 = target version
  bash "$SCRIPT" --mode=rewrite --version="$2" < "$1" > "$BATS_TEST_TMPDIR/out.json"
}

@test "rewrite: changes exactly one line" {
  rw "$MFX/plain.json" 9.15.9
  run diff "$MFX/plain.json" "$BATS_TEST_TMPDIR/out.json"
  # `run` reassigns $output to diff's output. Exactly one changed line yields
  # exactly one `<` and one `>`. Do not assert on diff's status: it exits 1
  # whenever the files differ, which is the expected outcome here.
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ]
}

@test "rewrite: sets the requested version" {
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$MFX/plain.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"packageManager": "pnpm@9.15.9"'* ]] || return 1
}

@test "rewrite: preserves tab indentation everywhere else" {
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$MFX/tabs.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t"name": "example"'* ]] || return 1
}

@test "rewrite: minified manifest keeps its exact byte length" {
  rw "$MFX/minified.json" 9.15.9
  # Same-length version swap; a gained trailing newline would show as +1.
  [ "$(wc -c < "$BATS_TEST_TMPDIR/out.json")" -eq "$(wc -c < "$MFX/minified.json")" ]
  grep -qF '"packageManager":"pnpm@9.15.9"' "$BATS_TEST_TMPDIR/out.json"
  grep -qF '"private":true' "$BATS_TEST_TMPDIR/out.json"
}

@test "rewrite: a manifest with no final newline does not gain one" {
  printf '{"packageManager":"pnpm@9.15.0"}' > "$BATS_TEST_TMPDIR/nonl.json"
  rw "$BATS_TEST_TMPDIR/nonl.json" 9.15.9
  [ "$(tail -c 1 "$BATS_TEST_TMPDIR/out.json")" = "}" ]
}

@test "rewrite: a manifest with a final newline keeps it" {
  rw "$MFX/plain.json" 9.15.9
  [ "$(wc -l < "$BATS_TEST_TMPDIR/out.json")" -eq "$(wc -l < "$MFX/plain.json")" ]
}

@test "rewrite: CRLF line endings survive byte-for-byte" {
  printf '{\r\n  "packageManager": "pnpm@9.15.0"\r\n}\r\n' > "$BATS_TEST_TMPDIR/crlf.json"
  rw "$BATS_TEST_TMPDIR/crlf.json" 9.15.9
  sed 's/9\.15\.0/9.15.9/' "$BATS_TEST_TMPDIR/crlf.json" > "$BATS_TEST_TMPDIR/want.json"
  cmp "$BATS_TEST_TMPDIR/want.json" "$BATS_TEST_TMPDIR/out.json"
}

@test "rewrite: replaces a sha512 hashed value wholesale" {
  printf '{"packageManager":"pnpm@9.15.0+sha512.abc.def"}' > "$BATS_TEST_TMPDIR/h512.json"
  rw "$BATS_TEST_TMPDIR/h512.json" '9.15.9+sha512.beef'
  grep -qF 'pnpm@9.15.9+sha512.beef' "$BATS_TEST_TMPDIR/out.json"
  ! grep -qF 'abc.def' "$BATS_TEST_TMPDIR/out.json"
}

@test "rewrite: a nested key with a DIFFERENT value leaves the nested one alone" {
  printf '{\n  "config": { "packageManager": "pnpm@8.0.0" },\n  "packageManager": "pnpm@9.15.0"\n}\n' \
    > "$BATS_TEST_TMPDIR/nd.json"
  rw "$BATS_TEST_TMPDIR/nd.json" 9.15.9
  grep -qF '"pnpm@8.0.0"' "$BATS_TEST_TMPDIR/out.json"
  grep -qF '"packageManager": "pnpm@9.15.9"' "$BATS_TEST_TMPDIR/out.json"
}

@test "rewrite: a nested key with the SAME value fails closed" {
  # The exact shape that silently produced a wrong PR in an earlier revision:
  # positional replacement edited the nested key and left the real pin stale.
  printf '{\n  "config": { "packageManager": "pnpm@9.15.0" },\n  "packageManager": "pnpm@9.15.0"\n}\n' \
    > "$BATS_TEST_TMPDIR/dup.json"
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$BATS_TEST_TMPDIR/dup.json"
  [ "$status" -eq 4 ]
  [[ "$output" == *"ambiguous"* ]] || return 1
}

@test "rewrite: rejects a nested-only packageManager" {
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$MFX/nested-decoy.json"
  [ "$status" -eq 2 ]
}

@test "rewrite: requires --version" {
  run bash "$SCRIPT" --mode=rewrite < "$MFX/plain.json"
  [ "$status" -eq 2 ]
}

@test "rewrite: output is still valid JSON" {
  rw "$MFX/plain.json" 9.15.9
  jq -e . < "$BATS_TEST_TMPDIR/out.json" >/dev/null
}

# The brief's Step 1 test list did not include a fixture reaching the
# --version format guard (line 164-165) or the rewrite-mode not-pnpm /
# not-exact guards (lines 171, 172-173), even though the implementation in
# Step 3 has them. Per the task's guard-coverage requirement, added here.

@test "rewrite: malformed --version fails" {
  run bash "$SCRIPT" --mode=rewrite --version=abc < "$MFX/plain.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--version is not x.y.z"* ]] || return 1
}

@test "rewrite: npm packageManager is out of scope" {
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$MFX/npm-pm.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not pnpm"* ]] || return 1
}

@test "rewrite: range instead of exact version fails" {
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$MFX/range.json"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not an exact"* ]] || return 1
}

@test "rewrite: JSON-escaped key passes jq validation but fails the literal scan" {
  # escaped-pin.json spells the key as "packageManager" — jq decodes this
  # to packageManager and the top-level/pnpm/exact-version validation (the
  # same one --mode=current uses) succeeds, but the document does not
  # literally contain the bytes "packageManager". The awk scan is a literal
  # byte scan, not a JSON-aware one, so it must reach count==0 and fail
  # closed here rather than silently doing nothing or corrupting the file.
  run bash "$SCRIPT" --mode=rewrite --version=9.15.9 < "$MFX/escaped-pin.json"
  [ "$status" -eq 2 ]
  # "could not locate" is unique to this branch: grep -c confirms exactly one
  # occurrence in the script, so this can't be a substring collision with the
  # not-pnpm, not-exact, or ambiguous-manifest messages.
  [[ "$output" == *"could not locate"* ]] || return 1
}
