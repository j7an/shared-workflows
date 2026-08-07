#!/usr/bin/env bash
# packagemanager-bump.sh — all package.json#packageManager semantics for pnpm.
#
# Pure stdin -> stdout. No network, no file reads. Bash 3.2 compatible.
#
# Modes:
#   --mode=current
#       stdin:  package.json
#       stdout: pnpm<TAB><version><TAB><major><TAB><suffix>
#               <suffix> is the full "+sha224.<hex>" or empty.
#   --mode=select --current=<x.y.z> --now=<epoch> --min-age-days=<n>
#       stdin:  the npm registry packument for pnpm
#       stdout: <version><TAB>normal|bypass, or nothing when none is eligible
#   --mode=rewrite --version=<x.y.z[+suffix]>
#       stdin:  package.json
#       stdout: the same document with only the packageManager value replaced
#
# Exit: 0 success (including the zero-result case)
#       2 malformed input, missing/repeated --mode, unknown argument
#       3 (select only) pinned version deprecated, no eligible replacement
set -uo pipefail

die() { echo "packagemanager-bump.sh: $1" >&2; exit "${2:-2}"; }

MODE=""; CURRENT=""; NOW=""; MIN_AGE_DAYS=""; VERSION=""
for arg in "$@"; do
  case "$arg" in
    --mode=current|--mode=select|--mode=rewrite)
      [ -n "$MODE" ] && die "repeated --mode"
      MODE="${arg#--mode=}"
      ;;
    --mode=*)         die "unknown mode: ${arg#--mode=}" ;;
    --current=*)      CURRENT="${arg#--current=}" ;;
    --now=*)          NOW="${arg#--now=}" ;;
    --min-age-days=*) MIN_AGE_DAYS="${arg#--min-age-days=}" ;;
    --version=*)      VERSION="${arg#--version=}" ;;
    *)                die "unknown argument: $arg" ;;
  esac
done

[ -n "$MODE" ] || die "--mode=current, --mode=select, or --mode=rewrite required"

# Plain $(cat) strips ALL trailing newlines, which would make --mode=rewrite
# silently drop a manifest's final newline. The sentinel round-trips them.
INPUT=$(cat; printf 'X')
INPUT="${INPUT%X}"

case "$MODE" in
  current)
    raw=$(printf '%s' "$INPUT" | jq -er '.packageManager // empty' 2>/dev/null) \
      || die "package.json is not valid JSON, or has no top-level packageManager"
    [ -n "$raw" ] || die "no top-level packageManager field"
    case "$raw" in
      pnpm@*) ;;
      *)      die "packageManager is not pnpm: $raw" ;;
    esac
    rest="${raw#pnpm@}"
    ver="${rest%%+*}"
    if [ "$ver" = "$rest" ]; then suffix=""; else suffix="+${rest#*+}"; fi
    [[ "$ver" =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]] \
      || die "packageManager version is not an exact x.y.z: $ver"
    printf 'pnpm\t%s\t%s\t%s\n' "$ver" "${BASH_REMATCH[1]}" "$suffix"
    ;;
  select)  die "not implemented" ;;
  rewrite) die "not implemented" ;;
esac
