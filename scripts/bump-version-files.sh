#!/usr/bin/env bash
# bump-version-files.sh — apply version bumps from .version-bump.json
#
# Reads .version-bump.json and writes the supplied version into each
# entry's target. Supports two per-entry forms (mutually exclusive):
#
#   { "path": "X.json", "field": "version" }                 — legacy
#   { "path": "X.json", "path_expr": ".pkg[0].version" }     — new
#
# Usage:
#   ./scripts/bump-version-files.sh <config-path> <version>
#   VERSION=1.2.3 ./scripts/bump-version-files.sh .version-bump.json
#
# Exit codes:
#   0 — at least one entry was modified (caller should commit)
#   1 — config error: malformed JSON, missing files array, schema
#       violation. Caller MUST fail the workflow.
#   2 — config valid but nothing modified: no config file, or all
#       entries already up to date, or all entries skipped. Caller
#       should NOT commit, but workflow continues.

set -euo pipefail

# Strict allowlist: identifiers, integer indices, and bracket-quoted string
# keys (npm/composer style: kebab-case, @scope/pkg, dotted paths). The jq []
# iterator is reserved for a follow-up minor release in this PR.
PATH_EXPR_RE='^\.[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*|\[[0-9]+\]|\["[A-Za-z0-9._@/-]+"\])*$'

validate_path_expr() {
  local expr="$1"
  printf '%s' "$expr" | grep -qE "$PATH_EXPR_RE"
}

display_path() {
  local field="$1" path_expr="$2"
  if [ -n "$path_expr" ]; then
    printf '%s' "$path_expr"
  else
    printf '.%s' "$field"
  fi
}

read_current() {
  local file="$1" field="$2" path_expr="$3"
  if [ -n "$path_expr" ]; then
    jq -r "$path_expr" "$file"
  else
    jq -r --arg f "$field" '.[$f]' "$file"
  fi
}

write_value() {
  local file="$1" field="$2" path_expr="$3" version="$4" tmpfile
  tmpfile=$(mktemp)
  if [ -n "$path_expr" ]; then
    jq --indent 2 --arg v "$version" "$path_expr = \$v" "$file" > "$tmpfile"
  else
    jq --indent 2 --arg f "$field" --arg v "$version" '.[$f] = $v' "$file" > "$tmpfile"
  fi
  mv "$tmpfile" "$file"
}

# bump_entry — process one .files[] entry
# Returns 0 if file was modified, 1 if skipped (any reason).
bump_entry() {
  local file_path="$1" field="$2" path_expr="$3" version="$4"
  local disp; disp=$(display_path "$field" "$path_expr")

  if [ -n "$path_expr" ] && ! validate_path_expr "$path_expr"; then
    printf '::error file=.version-bump.json::Entry for %q has invalid path_expr %q\n' \
      "$file_path" "$path_expr" >&2
    printf '| `%s` | `%s` | - | skipped (invalid path_expr) |\n' "$file_path" "$disp"
    return 1
  fi

  case "$file_path" in
    /*|*..*)
      printf '::warning::%s contains path traversal or is absolute\n' "$file_path" >&2
      printf '| `%s` | `%s` | - | skipped (unsafe path) |\n' "$file_path" "$disp"
      return 1 ;;
  esac
  if [ ! -f "$file_path" ]; then
    printf '::warning::%s not found\n' "$file_path" >&2
    printf '| `%s` | `%s` | - | skipped (file not found) |\n' "$file_path" "$disp"
    return 1
  fi
  case "$file_path" in
    *.json) ;;
    *)
      printf '::warning::%s is not a JSON file\n' "$file_path" >&2
      printf '| `%s` | `%s` | - | skipped (not JSON) |\n' "$file_path" "$disp"
      return 1 ;;
  esac
  if ! jq -e . "$file_path" >/dev/null 2>&1; then
    printf '::warning::%s is not valid JSON\n' "$file_path" >&2
    printf '| `%s` | `%s` | - | skipped (invalid JSON) |\n' "$file_path" "$disp"
    return 1
  fi

  local current; current=$(read_current "$file_path" "$field" "$path_expr")
  if [ "$current" = "$version" ]; then
    printf '| `%s` | `%s` | `%s` | already up to date |\n' "$file_path" "$disp" "$current"
    return 1
  fi

  write_value "$file_path" "$field" "$path_expr" "$version"
  printf '| `%s` | `%s` | `%s` -> `%s` | updated |\n' \
    "$file_path" "$disp" "$current" "$version"
  return 0
}

# --- Main procedural body ---

config="${1:-.version-bump.json}"
version="${2:-${VERSION:-}}"
: "${version:?usage: $0 <config> <version> | VERSION=X $0 [config]}"

if [ ! -f "$config" ]; then
  echo "No $config found, skipping version file bump"
  exit 2
fi

if ! jq -e '.files | type == "array" and length > 0' "$config" >/dev/null 2>&1; then
  echo "::error::$config is missing or has an invalid 'files' array" >&2
  exit 1
fi

# Schema validation pass — hard fail before touching any file
while IFS= read -r row; do
  file_path=$(jq -r '.path // ""' <<<"$row")
  field=$(jq -r '.field // ""' <<<"$row")
  path_expr=$(jq -r '.path_expr // ""' <<<"$row")

  if [ -z "$file_path" ]; then
    echo "::error::$config has an entry missing 'path'" >&2
    exit 1
  fi
  if [ -n "$field" ] && [ -n "$path_expr" ]; then
    echo "::error::$config entry for '$file_path' has both 'field' and 'path_expr' (mutually exclusive)" >&2
    exit 1
  fi
  if [ -z "$field" ] && [ -z "$path_expr" ]; then
    echo "::error::$config entry for '$file_path' has neither 'field' nor 'path_expr'" >&2
    exit 1
  fi
done < <(jq -c '.files[]' "$config")

# Apply pass — per-entry, accumulates summary
changed=0
while IFS= read -r row; do
  file_path=$(jq -r '.path // ""' <<<"$row")
  field=$(jq -r '.field // ""' <<<"$row")
  path_expr=$(jq -r '.path_expr // ""' <<<"$row")
  if bump_entry "$file_path" "$field" "$path_expr" "$version"; then
    changed=1
  fi
done < <(jq -c '.files[]' "$config")

if [ "$changed" -eq 1 ]; then
  exit 0
else
  exit 2
fi
