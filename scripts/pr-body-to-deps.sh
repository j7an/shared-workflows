#!/usr/bin/env bash
# pr-body-to-deps.sh — extract Dependabot dep bumps from a PR body, emit TSV.
# Defense-in-depth fallback for when extract-deps.sh returns zero rows.
#
# Arg:    <ecosystem>  — 'pypi' or 'actions'; emitted verbatim in TSV col 3.
# Input:  PR body text on stdin.
# Output: <name>\t<version>\t<ecosystem>  sorted, deduplicated.
# Exit:   0 on success (including zero rows), 2 if ecosystem arg invalid.

set -euo pipefail

ecosystem="${1:-}"
case "$ecosystem" in
  pypi|actions) ;;
  *) echo "pr-body-to-deps.sh: ecosystem must be 'pypi' or 'actions'" >&2; exit 2 ;;
esac

input=$(cat)
[ -z "$input" ] && exit 0

seen=$'\n'
rows=()
VER='[0-9][0-9A-Za-z.+!\-]*'

# Regex patterns stored in variables — bash 3.2 on macOS cannot parse certain
# metacharacters (like `)`) inline within [[ =~ ]] conditionals.
# Pattern A — Bumps [name](url) ... from X to Y
re_a="^Bumps[[:space:]]\[([^]]+)\][^f]*from[[:space:]]+${VER}[[:space:]]+to[[:space:]]+(${VER})"
# Pattern B — Updates `name` from X to Y (anchored at column 0 to avoid
# matching blockquote/release-notes content which is typically indented)
re_b="^Updates[[:space:]]\`([^\`]+)\`[[:space:]]+from[[:space:]]+${VER}[[:space:]]+to[[:space:]]+(${VER})"
# Pattern C — | [name](url) | `fromVer` | `toVer` |
re_c="^\|[[:space:]]+\[([^]]+)\]\([^)]+\)[[:space:]]+\|[[:space:]]+\`${VER}\`[[:space:]]+\|[[:space:]]+\`(${VER})\`[[:space:]]+\|"

while IFS= read -r line; do
  line="${line%$'\r'}"
  name=""
  version=""

  if [[ "$line" =~ $re_a ]]; then
    name="${BASH_REMATCH[1]}"; version="${BASH_REMATCH[2]}"
  elif [[ "$line" =~ $re_b ]]; then
    name="${BASH_REMATCH[1]}"; version="${BASH_REMATCH[2]}"
  elif [[ "$line" =~ $re_c ]]; then
    name="${BASH_REMATCH[1]}"; version="${BASH_REMATCH[2]}"
  fi

  [ -z "$name" ] && continue

  # Strip trailing sentence punctuation from the version (e.g. "2.13.0."
  # in Pattern A's "Bumps ... from X to Y." lines).
  version="${version%.}"

  key="$ecosystem:$name"
  case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
  seen="${seen}${key}"$'\n'
  rows+=("$name"$'\t'"$version"$'\t'"$ecosystem")
done <<< "$input"

if [ ${#rows[@]} -gt 0 ]; then
  printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1
fi
