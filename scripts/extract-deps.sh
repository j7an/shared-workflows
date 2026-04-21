#!/usr/bin/env bash
# extract-deps.sh — parse unified diff on stdin, emit dependency TSV on stdout
#
# Output: <name>\t<version>\t<ecosystem>  where ecosystem ∈ {actions, pypi}
# Exit:   0 on success (possibly zero rows), 2 on malformed input
#
# Handles BOTH GitHub Actions shapes observed in real PR diffs:
#   +        uses: owner/repo@sha # vX.Y.Z        (no list marker)
#   +      - uses: owner/repo@sha # vX.Y.Z        (YAML list marker)
#
# The missing list-marker support in the v2.0.1 regex `^\+\s+uses:` is the
# root cause of issue #27 (astral-sh/setup-uv silently dropped from
# nexus-mcp#160's cooldown scan).

set -euo pipefail

# Dedup sentinel: newline-delimited list of "ecosystem:name" keys.
# Using a plain string (not `declare -A`) for bash 3.2 compatibility, since
# macOS's system bash is still 3.2 and the bats test invokes `bash` directly.
seen=$'\n'
rows=()

input=$(cat)

# Empty input → exit 0 with no output
if [ -z "$input" ]; then
  exit 0
fi

# Malformed input detection: if non-empty and has none of the unified-diff
# markers, reject with exit 2. Use a here-string instead of a pipeline so
# large valid diffs cannot trip SIGPIPE under `pipefail`.
if ! grep -qE '^(\+\+\+|---|@@|diff --git)' <<< "$input"; then
  echo "extract-deps.sh: input is not a unified diff" >&2
  exit 2
fi

while IFS= read -r line; do
  # Strip CR for CRLF-encoded diffs
  line="${line%$'\r'}"

  # Skip diff file headers (+++ b/path)
  [[ "$line" == +++* ]] && continue

  # --- GitHub Actions parser ---
  # Matches both "+ uses: foo@..." and "+ - uses: foo@..."
  if [[ "$line" =~ ^\+[[:space:]]+(-[[:space:]]+)?uses:[[:space:]]+([^[:space:]@]+)@[^[:space:]]+(.*)$ ]]; then
    name="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"

    # Skip local and docker actions
    [[ "$name" == ./* ]] && continue
    [[ "$name" == docker://* ]] && continue

    version=""
    # Capture version from trailing comment: " # v1.2.3" or " # 1.2.3"
    # The `v?` is OUTSIDE the capture group so we strip the leading v.
    if [[ "$rest" =~ \#[[:space:]]*v?([0-9][0-9.]*) ]]; then
      version="${BASH_REMATCH[1]}"
    fi

    key="actions:$name"
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen="${seen}${key}"$'\n'
    rows+=("$name"$'\t'"$version"$'\t'"actions")
    continue
  fi

  # --- Python deps parser ---
  # Skip Python-style comment lines first
  [[ "$line" =~ ^\+[[:space:]]*# ]] && continue

  if [[ "$line" =~ ^\+[[:space:]]*([a-zA-Z][a-zA-Z0-9_.\-]*)[[:space:]]*(==|\>=|\<=|~=|\!=|\>|\<)[[:space:]]*([0-9][0-9a-zA-Z.\-]*) ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[3]}"
    key="pypi:$name"
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen="${seen}${key}"$'\n'
    rows+=("$name"$'\t'"$version"$'\t'"pypi")
    continue
  fi
done <<< "$input"

if [ ${#rows[@]} -gt 0 ]; then
  printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1
fi
