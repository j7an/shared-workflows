bats_require_minimum_version 1.5.0
#!/usr/bin/env bats

SCRIPT="scripts/packagemanager-integrity.sh"
FX="tests/fixtures/packagemanager-integrity"

# ---------------------------------------------------------------------------
# Fixture digests.
#
# The two payloads are 512 deterministic bytes each, committed under
# tests/fixtures/packagemanager-integrity/:
#
#   payload.bin        perl -e 'print map { chr($_ % 256) } 0..511'
#   payload-other.bin  perl -e 'print map { chr(255 - ($_ % 256)) } 0..511'
#
# The digests below were computed on 2026-08-06 with two tools independent of
# the script under test, which agreed:
#
#   shasum -a 512 payload.bin              # -> PAYLOAD_SHA512
#   openssl dgst -sha512 payload.bin
#   shasum -a 224 payload.bin              # -> PAYLOAD_SHA224
#   openssl dgst -sha224 payload.bin
#   shasum -a 512 payload-other.bin        # -> OTHER_SHA512
#   openssl dgst -sha512 payload-other.bin
#
# The SRI base64 forms were derived as:
#
#   openssl dgst -sha512 -binary payload.bin | openssl base64 -A
#
# These are fixture literals the suite defines for itself - inputs, not claims
# about the world - so the no-hardcoded-external-versions rule does not apply.
# Nothing here names a pnpm version or an action SHA.
# ---------------------------------------------------------------------------

PAYLOAD_SHA512="edb9bed721aa6a5f6fbc6619d3a3c2be3d043043f05a9aebc7b1197a2aa9c49a57d5ddd4674c1785785088d9f1ff42c797a02adc9b817a139a50970da6c99524"
PAYLOAD_SHA224="b8060ccc82d40c576156f7ca0333e4389e410df027d2fb8f764fa603"
OTHER_SHA512="b5f82bdbf45c433ba79b95192b42adde4741b042877b6320b8f9fd5238070ccd2193a7b2810391afe02105a8032214c520c4c9801a6aede48f75fdf8bb5b26c2"

PAYLOAD_SRI512="sha512-7bm+1yGqal9vvGYZ06PCvj0EMEPwWprrx7EZeiqpxJpX1d3UZ0wXhXhQiNnx/0LHl6Aq3JuBehOaUJcNpsmVJA=="
OTHER_SRI512="sha512-tfgr2/RcQzunm5UZK0Kt3kdBsEKHe2MguPn9UjgHDM0hk6eygQORr+AhBagDIhTFIMTJgBpq7eSPdf34u1smwg=="

# --- Case 1: known bytes -> known hex ---------------------------------------

# --separate-stderr, not plain `run`: with no --expect the script warns on
# stderr, and plain `run` would fold that warning into $output and redden an
# otherwise-correct digest.
@test "known bytes produce the independently computed sha512 hex" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512
  [ "$status" -eq 0 ]
  [ "$output" = "sha512.${PAYLOAD_SHA512}" ]
}

@test "a matching --expect claim verifies and still emits the sha512 suffix body" {
  run bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512 --expect="$PAYLOAD_SRI512"
  [ "$status" -eq 0 ]
  [ "$output" = "sha512.${PAYLOAD_SHA512}" ]
}

@test "the emitted suffix body carries no leading plus" {
  run bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512 --expect="$PAYLOAD_SRI512"
  [ "$status" -eq 0 ]
  case "$output" in
    +*) return 1 ;;
  esac
}

@test "a successful run writes nothing to stderr when a claim was supplied" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="$PAYLOAD_SRI512"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

# --- Case 2: tampered bytes -> integrity-failure ----------------------------
#
# `--expect` carries a well-formed sha512 SRI for payload-other.bin while the
# tarball is payload.bin. Status alone does not discriminate: exit 2 and exit 5
# would both be "not zero", and several distinct failures share exit 2. Assert
# the reason text, not just the number.

@test "bytes that do not match --expect exit 5" {
  run bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512 --expect="$OTHER_SRI512"
  [ "$status" -eq 5 ]
}

@test "a mismatch reports integrity-failure on stderr" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="$OTHER_SRI512"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"integrity-failure"* ]] || return 1
}

@test "a mismatch names both the computed and the expected digest" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="$OTHER_SRI512"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"$PAYLOAD_SHA512"* ]] || return 1
  [[ "$stderr" == *"$OTHER_SHA512"* ]] || return 1
}

# Verification runs BEFORE hashing. If the order were reversed the suffix body
# would already be on stdout by the time the claim was checked, and the caller's
# command substitution would capture a digest of unverified bytes.
@test "a mismatch emits no suffix body on stdout" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="$OTHER_SRI512"
  [ "$status" -eq 5 ]
  [ -z "$output" ]
}

# --- Case 3: missing / unreadable tarball -> exit 2, distinct from 5 --------

@test "a missing tarball exits 2, not 5" {
  run bash "$SCRIPT" --tarball="$FX/does-not-exist.bin" --algo=sha512
  [ "$status" -eq 2 ]
}

@test "a missing tarball says the tarball was not found" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/does-not-exist.bin" --algo=sha512
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"tarball not found"* ]] || return 1
  [ -z "$output" ]
}

@test "a missing tarball is refused even when a claim is supplied" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/does-not-exist.bin" --algo=sha512 --expect="$PAYLOAD_SRI512"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"tarball not found"* ]] || return 1
}

@test "a directory in place of a tarball exits 2 with its own reason" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX" --algo=sha512
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not a regular file"* ]] || return 1
}

# --- Case 4: LOAD-BEARING. --algo governs output, --expect governs verify ----
#
# A sha224 pin checked against the registry's sha512 claim must verify with
# sha512 and emit sha224. This is the only test that fails if the implementation
# derives the output algorithm from --expect: every other case here uses sha512
# for both, so the two sources are indistinguishable in them. Confirmed RED on
# 2026-08-06 under exactly that mutation (output algo taken from --expect).

@test "a sha224 pin verified against a sha512 claim stays sha224" {
  run bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha224 --expect="$PAYLOAD_SRI512"
  [ "$status" -eq 0 ]
  [ "$output" = "sha224.${PAYLOAD_SHA224}" ]
}

@test "a sha224 pin still verifies with sha512 and rejects wrong bytes" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha224 --expect="$OTHER_SRI512"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *"integrity-failure"* ]] || return 1
  [[ "$stderr" == *"sha512"* ]] || return 1
  [ -z "$output" ]
}

# --- Case 5: empty --expect skips verification and warns on stderr ----------
#
# bats folds stderr into $output under plain `run` and strips trailing
# newlines, so a warning asserted through $output proves nothing about which
# stream carried it. --separate-stderr is what binds the contract: the suffix
# body must be the whole of stdout so the caller's `$(...)` stays clean.

@test "an empty --expect skips verification and still emits the digest" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512 --expect=
  [ "$status" -eq 0 ]
  [ "$output" = "sha512.${PAYLOAD_SHA512}" ]
}

@test "an empty --expect warns on stderr, not on stdout" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512 --expect=
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"skipping byte verification"* ]] || return 1
  [[ "$output" != *"skipping byte verification"* ]] || return 1
}

@test "an absent --expect flag behaves the same as an empty one" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=sha512
  [ "$status" -eq 0 ]
  [ "$output" = "sha512.${PAYLOAD_SHA512}" ]
  [[ "$stderr" == *"skipping byte verification"* ]] || return 1
}

# --- Argument handling ------------------------------------------------------

@test "a missing --tarball exits 2" {
  run --separate-stderr bash "$SCRIPT" --algo=sha512
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--tarball"* ]] || return 1
}

@test "a missing --algo exits 2" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/payload.bin"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--algo"* ]] || return 1
}

@test "an unknown argument exits 2" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --frobnicate
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown argument"* ]] || return 1
  [[ "$stderr" == *"frobnicate"* ]] || return 1
}

@test "an --algo outside the allowlist exits 2" {
  run --separate-stderr bash "$SCRIPT" --tarball="$FX/payload.bin" --algo=md5
  [ "$status" -eq 2 ]
  # "unsupported --algo" and not merely "*md5*": the unknown-argument catch-all
  # would also mention md5, so a substring match on the value alone would not
  # tell the allowlist guard from the parser falling through to it.
  [[ "$stderr" == *"unsupported --algo"* ]] || return 1
}

@test "an --expect algorithm outside the allowlist exits 2, not 5" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="md5-1B2M2Y8AsgTpgAmY7PhCfg=="
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unsupported --expect algorithm"* ]] || return 1
}

@test "an --expect without the SRI dash exits 2, not 5" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="deadbeef"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not SRI form"* ]] || return 1
}

@test "an --expect whose base64 is not base64 exits 2, not 5" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect='sha512-not valid base64!'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not base64"* ]] || return 1
}

# A truncated claim decodes cleanly as base64 but is the wrong digest length.
# Reporting that as exit 5 would let a malformed packument masquerade as
# tampered bytes; the operator needs to be able to tell those apart.
@test "an --expect of the wrong digest length for its algorithm exits 2, not 5" {
  run --separate-stderr bash "$SCRIPT" \
    --tarball="$FX/payload.bin" --algo=sha512 --expect="sha512-3q2+7w=="
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"not a valid sha512 digest"* ]] || return 1
}

# --- Inline copy parity -----------------------------------------------------
#
# check-inline-sync.sh proves the embedded text matches byte-for-byte. This
# proves the embedded text is a *runnable function* under the wrapper the
# workflow applies to it - a sync check passes just as happily on a copy that
# was never valid inside `fn() ( ... )`.

@test "the inline copy runs as the packagemanager_integrity function" {
  workflow=".github/workflows/pnpm-packagemanager-update.yml"
  block="$BATS_TEST_TMPDIR/fn.sh"
  awk '
    /# --- BEGIN inline:scripts\/packagemanager-integrity.sh ---/ { inside=1; next }
    /# --- END inline:scripts\/packagemanager-integrity.sh ---/   { inside=0; next }
    inside { sub(/^ {10}/, ""); print }
  ' "$workflow" > "$block"
  [ -s "$block" ]

  run --separate-stderr bash -c ". '$block'; packagemanager_integrity --tarball='$FX/payload.bin' --algo=sha512"
  [ "$status" -eq 0 ]
  [ "$output" = "sha512.${PAYLOAD_SHA512}" ]
}

@test "the inline copy reports integrity-failure with exit 5" {
  workflow=".github/workflows/pnpm-packagemanager-update.yml"
  block="$BATS_TEST_TMPDIR/fn.sh"
  awk '
    /# --- BEGIN inline:scripts\/packagemanager-integrity.sh ---/ { inside=1; next }
    /# --- END inline:scripts\/packagemanager-integrity.sh ---/   { inside=0; next }
    inside { sub(/^ {10}/, ""); print }
  ' "$workflow" > "$block"

  run bash -c ". '$block'; packagemanager_integrity --tarball='$FX/payload.bin' --algo=sha512 --expect='$OTHER_SRI512'"
  [ "$status" -eq 5 ]
  [[ "$output" == *"integrity-failure"* ]] || return 1
}
