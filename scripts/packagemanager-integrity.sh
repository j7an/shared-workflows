#!/usr/bin/env bash
# packagemanager-integrity.sh - verify a downloaded tarball against the registry's
# own SRI claim, then emit the Corepack integrity suffix body.
#
# Usage:
#   packagemanager-integrity.sh --tarball=<path> --algo=<name> [--expect=<sri>]
#
# --algo    algorithm for the OUTPUT digest, taken from the algorithm the pin
#           already declares. Allowlist: sha512 sha384 sha256 sha224 sha1.
# --expect  the packument's `dist.integrity`, SRI form `<algo>-<base64>`. When
#           empty or absent, byte verification is skipped and a warning goes to
#           stderr - the caller decided the packument had no claim to check.
#
# stdout    `<algo>.<lowercase-hex>` - the suffix body, WITHOUT the leading `+`.
# exit 0    success
# exit 2    malformed arguments, unreadable tarball, or unsupported algorithm
# exit 5    integrity-failure: bytes do not match --expect
#
# No network. Bash 3.2 compatible. The caller downloads the tarball; keeping the
# fetch out of here is what makes every path testable offline from a fixture.
#
# Two properties are load-bearing and silent when wrong:
#
#   1. --algo governs the OUTPUT digest; --expect's own algorithm governs
#      VERIFICATION. They are independent. A sha224 pin verified against a
#      sha512-... claim must verify with sha512 and emit sha224. Deriving one
#      from the other silently upgrades a sha224 pin to the default, and no
#      exit status changes to announce it.
#   2. Verification runs BEFORE the output digest is computed. Hashing
#      unverified bytes faithfully records whatever was downloaded, which is
#      precisely the failure this gate exists to prevent.
#
# Corepack's contract, confirmed by round-trip against corepack 0.35.0 on
# 2026-08-06 (`corepack use pnpm@11.20.0` in a scratch project): the suffix body
# is the digest of the downloaded tarball *stream*, lowercase hex, and it agreed
# byte-for-byte with both `openssl dgst -sha512` over the registry tarball and
# with the registry's own dist.integrity decoded from base64. The extracted-file
# branch in corepackUtils.ts does not apply to a pnpm tarball.
#
# openssl is used rather than shasum/base64 for portability: `openssl dgst -hex`
# emits lowercase hex on both OpenSSL 1.1 (`SHA512(f)= ...`) and 3.x
# (`SHA2-512(f)= ...`), and `awk '{print $NF}'` strips either prefix. macOS
# `base64` wants -D where GNU wants -d; `openssl base64 -d -A` is the same
# everywhere.
set -uo pipefail

die() { echo "packagemanager-integrity.sh: $1" >&2; exit "${2:-2}"; }

# Digest byte length per algorithm, as hex characters. Bash 3.2 has no
# associative arrays, so this is a case, not a map.
hex_len_for() {
  case "$1" in
    sha512) echo 128 ;;
    sha384) echo 96  ;;
    sha256) echo 64  ;;
    sha224) echo 56  ;;
    sha1)   echo 40  ;;
    *)      echo 0   ;;
  esac
}

TARBALL=""; ALGO=""; EXPECT=""
for arg in "$@"; do
  case "$arg" in
    --tarball=*) TARBALL="${arg#--tarball=}" ;;
    --algo=*)    ALGO="${arg#--algo=}" ;;
    --expect=*)  EXPECT="${arg#--expect=}" ;;
    *)           die "unknown argument: $arg" ;;
  esac
done

[ -n "$TARBALL" ] || die "--tarball=<path> required"
[ -n "$ALGO" ]    || die "--algo=<name> required"

# The allowlist is what keeps --algo out of the openssl command line as an
# arbitrary string. Reject before touching the filesystem.
[ "$(hex_len_for "$ALGO")" != "0" ] || die "unsupported --algo: $ALGO"

# An absent file must not read as a pass. A fetch failure is the caller's to
# diagnose, but silence here would let it become a hash of nothing.
[ -e "$TARBALL" ] || die "tarball not found: $TARBALL"
[ -f "$TARBALL" ] || die "tarball is not a regular file: $TARBALL"
[ -r "$TARBALL" ] || die "tarball is not readable: $TARBALL"

# --- Verification. Runs before any output digest is computed. ---
if [ -n "$EXPECT" ]; then
  case "$EXPECT" in
    *-*) ;;
    *)   die "--expect is not SRI form <algo>-<base64>: $EXPECT" ;;
  esac
  EXP_ALGO="${EXPECT%%-*}"
  EXP_B64="${EXPECT#*-}"

  EXP_HEX_LEN=$(hex_len_for "$EXP_ALGO")
  [ "$EXP_HEX_LEN" != "0" ] || die "unsupported --expect algorithm: $EXP_ALGO"
  [ -n "$EXP_B64" ] || die "--expect carries no digest: $EXPECT"

  # openssl base64 -d is lenient about garbage, so screen the charset first and
  # confirm the decoded length afterwards. A claim that cannot be read is a
  # malformed argument (2), not an integrity failure (5) - conflating them would
  # let a truncated claim masquerade as tampered bytes.
  [[ "$EXP_B64" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
    || die "--expect digest is not base64: $EXPECT"
  EXP_HEX=$(printf '%s' "$EXP_B64" | openssl base64 -d -A 2>/dev/null | od -An -tx1 | tr -d ' \n') \
    || die "--expect digest could not be decoded: $EXPECT"
  [ "${#EXP_HEX}" -eq "$EXP_HEX_LEN" ] \
    || die "--expect digest is not a valid ${EXP_ALGO} digest: $EXPECT"

  # Verify with the CLAIM's algorithm, not --algo. These are independent.
  ACT_HEX=$(openssl dgst -"$EXP_ALGO" -hex "$TARBALL" | awk '{print $NF}') \
    || die "could not compute ${EXP_ALGO} digest of ${TARBALL}"
  [ "${#ACT_HEX}" -eq "$EXP_HEX_LEN" ] \
    || die "could not compute ${EXP_ALGO} digest of ${TARBALL}"

  if [ "$ACT_HEX" != "$EXP_HEX" ]; then
    die "integrity-failure: ${EXP_ALGO} of ${TARBALL} is ${ACT_HEX}, expected ${EXP_HEX}" 5
  fi
else
  echo "packagemanager-integrity.sh: warning: no --expect claim supplied; skipping byte verification" >&2
fi

# --- Output digest. Uses --algo, and only --algo. ---
OUT_HEX=$(openssl dgst -"$ALGO" -hex "$TARBALL" | awk '{print $NF}') \
  || die "could not compute ${ALGO} digest of ${TARBALL}"
OUT_LEN=$(hex_len_for "$ALGO")
[ "${#OUT_HEX}" -eq "$OUT_LEN" ] || die "could not compute ${ALGO} digest of ${TARBALL}"

printf '%s.%s\n' "$ALGO" "$OUT_HEX"
