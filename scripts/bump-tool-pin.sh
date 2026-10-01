#!/usr/bin/env bash
# bump-tool-pin.sh — select an aged stable GitHub release and update quoted pins.
#
# Usage: bump-tool-pin.sh <key> <min_age_days> <file>...
# Schema:
#   in:  GitHub releases JSON array
#   out: <old>\t<new>\t<tag>\t<published_at> (one row on a bump)
#
# Exit: 0 on bump or no-op; 2 on bad args, missing files, absent/disagreeing
# pins, or malformed input. No-op produces no stdout and leaves files intact.
# TOOL_PIN_NOW optionally overrides the current time with epoch seconds.
# Bash 3.2 compatible (macOS system bash); requires jq.

set -euo pipefail

[ "$#" -ge 3 ] || exit 2
key=$1
days=$2
shift 2
[[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || exit 2
[[ "$days" =~ ^[0-9]+$ ]] || exit 2
for file in "$@"; do
  [ -f "$file" ] || exit 2
done

pattern="^[[:space:]]+${key}: \"[0-9]+[.][0-9]+[.][0-9]+\"[[:space:]]*$"
cur=$(grep -hE -- "$pattern" "$@" | sed 's/^[^"]*"//; s/".*$//' | sort -u) || exit 2
[ -n "$cur" ] || exit 2
[[ "$cur" != *$'\n'* ]] || exit 2

input=$(cat) || exit 2
# Require exactly one JSON array, rejecting empty input and JSON streams.
printf '%s' "$input" | jq -e -s 'length == 1 and (.[0] | type == "array")' >/dev/null || exit 2
# Normalize leading zeros so any digit-only age is valid JSON as well.
days=$(printf '%s' "$days" | sed 's/^0*//')
result=$(printf '%s' "$input" | jq -r \
  --arg cur "$cur" --argjson days "${days:-0}" --argjson now "${TOOL_PIN_NOW:-null}" '
  def sv: ltrimstr("v") | split(".") | map(tonumber);
  ($now // now) as $t
  | [ .[] | select(.draft != true and .prerelease != true and .published_at != null)
          | select(.tag_name | test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))
          | select((.published_at | fromdateiso8601) <= ($t - $days * 86400)) ]
  | sort_by(.tag_name | sv) | last
  | if . != null and ((.tag_name | sv) > ($cur | sv))
    then [$cur, (.tag_name | ltrimstr("v")), .tag_name, .published_at] | @tsv
    else empty end
') || exit 2
[ -n "$result" ] || exit 0

IFS=$'\t' read -r old new _ <<< "$result"
for file in "$@"; do
  tmp=$(mktemp)
  # Match the same complete quoted pin as extraction; expressions stay intact.
  awk -v pattern="$pattern" -v old="\"$old\"" -v new="\"$new\"" '
    $0 ~ pattern { sub(old, new) }
    { print }
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm "$tmp"
done
printf '%s\n' "$result"
