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
#       4 (rewrite only) ambiguous-manifest: the target value appears under
#         more than one packageManager key; refusing textual replacement
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

    # has("deprecated") — NOT `.deprecated // empty`. A version deprecated with
    # an empty string is still deprecated, and `// empty` would read it as healthy.
    if printf '%s' "$INPUT" | jq -e --arg v "$CURRENT" \
         '.versions[$v] | has("deprecated")' >/dev/null 2>&1; then
      soak="0"; label="bypass"
      pin_dep=$(printf '%s' "$INPUT" | jq -r --arg v "$CURRENT" '.versions[$v].deprecated')
    else
      soak="1"; label="normal"; pin_dep=""
    fi

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
      if [ -n "$pin_dep" ]; then
        die "deprecated-no-escape: pinned version $CURRENT is deprecated and no eligible replacement exists in major $major: $pin_dep" 3
      fi
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
      # Structurally unreachable today: pin_dep non-empty implies soak="0",
      # which forces `selected` on every loop iteration whenever $cands is
      # non-empty, and the empty-$cands case was already intercepted above.
      # Kept as forward-defense against a future change to the loop's
      # selection logic; do not delete as a copy-paste artifact.
      if [ -n "$pin_dep" ]; then
        die "deprecated-no-escape: pinned version $CURRENT is deprecated and no eligible replacement exists in major $major: $pin_dep" 3
      fi
      echo "cooldown" >&2
      exit 0
    fi
    printf '%s\t%s\n' "$selected" "$label"
    exit 0
    ;;
  rewrite)
    [ -n "$VERSION" ] || die "--mode=rewrite requires --version"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+[A-Za-z0-9._-]+)?$ ]] \
      || die "--version is not x.y.z or x.y.z+suffix: $VERSION"

    # Validate the same way --mode=current does, so rewrite refuses everything
    # current refuses: absent field, non-pnpm, range, nested-only.
    raw=$(printf '%s' "$INPUT" | jq -er '.packageManager // empty' 2>/dev/null) \
      || die "package.json is not valid JSON, or has no top-level packageManager"
    case "$raw" in pnpm@*) ;; *) die "packageManager is not pnpm: $raw" ;; esac
    [[ "${raw#pnpm@}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\+.*)?$ ]] \
      || die "packageManager version is not an exact x.y.z: $raw"

    # Structure-aware, byte-preserving replacement. See the notes below —
    # every line of this is load-bearing and was validated empirically.
    printf '%sX' "$INPUT" | awk -v old="$raw" -v new="pnpm@$VERSION" '
      BEGIN { RS = "\0" }
      {
        s = substr($0, 1, length($0) - 1)   # drop the sentinel X
        key = "\"packageManager\""
        target = "\"" old "\""
        pos = 1; count = 0; hit = 0
        while ((i = index(substr(s, pos), key)) > 0) {
          abs = pos + i - 1
          j = abs + length(key)
          while (substr(s, j, 1) ~ /[ \t\r\n]/) j++
          if (substr(s, j, 1) == ":") {
            j++
            while (substr(s, j, 1) ~ /[ \t\r\n]/) j++
            if (substr(s, j, length(target)) == target) {
              count++
              if (count == 1) hit = j
            }
          }
          pos = abs + length(key)
        }
        if (count == 0) exit 3
        if (count > 1) exit 4
        printf "%s", substr(s, 1, hit - 1) "\"" new "\"" substr(s, hit + length(target))
      }'
    rc=$?
    [ "$rc" -eq 3 ] && die "could not locate the packageManager value in the document"
    [ "$rc" -eq 4 ] && die "ambiguous-manifest: the value $raw appears under more than one packageManager key; refusing textual replacement" 4
    [ "$rc" -eq 0 ] || die "rewrite failed"
    ;;
esac
