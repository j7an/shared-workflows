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
  select)
    [ -n "$CURRENT" ]      || die "--mode=select requires --current"
    [ -n "$NOW" ]          || die "--mode=select requires --now"
    [ -n "$MIN_AGE_DAYS" ] || die "--mode=select requires --min-age-days"
    [[ "$CURRENT" =~ ^([0-9]+)\.[0-9]+\.[0-9]+$ ]] || die "--current is not x.y.z: $CURRENT"
    major="${BASH_REMATCH[1]}"
    [[ "$NOW" =~ ^[0-9]+$ ]]          || die "--now is not an epoch: $NOW"
    [[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || die "--min-age-days is not a number: $MIN_AGE_DAYS"

    printf '%s' "$INPUT" | jq -e 'has("versions") and has("time")' >/dev/null 2>&1 \
      || die "packument is not valid JSON or lacks .versions/.time"

    # Any stable release in this major at all? Empty means the major is unknown
    # to the registry, which is a different condition from "nothing newer" and
    # must not be reported as a clean no-op.
    in_major=$(printf '%s' "$INPUT" | jq -r --arg maj "$major" '
      [ .versions | keys[] | select(test("^" + $maj + "\\.[0-9]+\\.[0-9]+$")) ] | length')
    [ "$in_major" -gt 0 ] || die "no published stable pnpm releases in major $major"

    # Candidates: stable, in-major, not deprecated, strictly newer.
    cands=$(printf '%s' "$INPUT" | jq -r \
      --arg maj "$major" --arg cur "$CURRENT" '
      def semver: split(".") | map(tonumber);
      [ .versions
        | to_entries[]
        | select(.key | test("^" + $maj + "\\.[0-9]+\\.[0-9]+$"))
        | select(.value | has("deprecated") | not)
        | .key
      ]
      | map(select(semver > ($cur | semver)))
      | sort_by(semver)[]') || die "packument selection failed"

    if [ -z "$cands" ]; then
      # Distinguish the reasons rather than reporting one undifferentiated no-op.
      # major-available is checked BEFORE prerelease-only: if the pinned major
      # is end-of-life, no stable release will ever land in it, so reporting
      # prerelease-only would imply a wait that never ends. major-available is
      # the honest, actionable signal whenever both are true. (Task 3 ruling,
      # 2026-08-06: this reorders the brief's prescribed check order.)
      if printf '%s' "$INPUT" | jq -e --arg maj "$major" '
           [ .versions | keys[]
             | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
             | select((split(".")[0] | tonumber) > ($maj | tonumber)) ] | length > 0
         ' >/dev/null 2>&1; then
        echo "major-available" >&2; exit 0
      fi
      if printf '%s' "$INPUT" | jq -e --arg maj "$major" --arg cur "$CURRENT" '
           def semver: split(".") | map(tonumber);
           [ .versions | keys[]
             | select(test("^" + $maj + "\\.[0-9]+\\.[0-9]+-"))
             | select((split("-")[0] | semver) > ($cur | semver)) ] | length > 0
         ' >/dev/null 2>&1; then
        echo "prerelease-only" >&2; exit 0
      fi
      echo "current" >&2; exit 0
    fi

    # Every candidate MUST have a timestamp. Silently dropping one would let a
    # malformed packument look like a clean cooldown, which is fail-open.
    soak="1"
    cutoff=$(( NOW - MIN_AGE_DAYS * 86400 ))
    selected=""
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      iso=$(printf '%s' "$INPUT" | jq -r --arg v "$v" '.time[$v] // empty')
      [ -n "$iso" ] || die "malformed-packument: no .time entry for candidate $v"
      pub=$(printf '%s' "$INPUT" | jq -r --arg t "$iso" \
              '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601') \
        || die "malformed-packument: unparseable timestamp for $v: $iso"
      if [ "$soak" = "0" ] || [ "$pub" -le "$cutoff" ]; then
        selected="$v"
      fi
    done <<< "$cands"

    if [ -z "$selected" ]; then
      echo "cooldown" >&2
      exit 0
    fi
    printf '%s\tnormal\n' "$selected"
    exit 0
    ;;
  rewrite) die "not implemented" ;;
esac
