#!/usr/bin/env bash
# extract-deps.sh — parse unified diff on stdin, emit dependency TSV on stdout
#
# Output: <name>\t<version>\t<ecosystem>  where ecosystem ∈ {actions, pypi, docker}
# Exit:   0 on success (possibly zero rows), 2 on malformed input
#
# Handles THREE shapes observed in real PR diffs:
#   1. GitHub Actions `uses:` lines (single-line name@version)
#   2. pip/requirements `name==version` single-line format
#   3. TOML lockfile [[package]] stanzas (uv.lock, poetry.lock) where the
#      name line may be on an unchanged context line while only the version
#      is `+`-prefixed — section-aware parsing required.
#
#   4. Dockerfile `FROM` lines (added lines only): emit
#      <image-without-tag-or-digest>\t<tag@digest | tag | digest | latest>\tdocker.
#      An added FROM line that cannot be parsed (e.g. `${BASE}` or a line
#      continuation) emits <raw token, or FROM>\t-\tdocker so the guard can
#      fail loud. Version is never empty (tab-`read` consumers collapse it).
#
# The TOML lockfile parser addresses issue #52: Dependabot bumps to uv.lock
# and poetry.lock previously yielded zero rows, cascading to silent-green
# cooldown gates on unscanned code.

set -euo pipefail

# pypi-shape lockfiles only. Cargo.lock / package-lock.json would need
# downstream ecosystem support (registry clients, OSV enums) before rows
# could be scanned — the fail-loud guard in dependency-safety.yml covers
# unhandled lockfiles.
filename_to_ecosystem() {
  case "$1" in
    uv.lock|poetry.lock) echo "pypi" ;;
    *) echo "" ;;
  esac
}

# Dedup sentinel: newline-delimited list of "ecosystem:name" keys.
# Plain string (not `declare -A`) for bash 3.2 compatibility — macOS ships
# bash 3.2 and bats invokes bash directly.
seen=$'\n'
rows=()

# Lockfile parser state
current_file=""
current_name=""
current_ecosystem=""
current_is_dockerfile=false
stage_names=$'\n'

# Dockerfile FROM parsing (regexes in variables: they contain `)` and `|`)
from_line_re='^\+[[:space:]]*[Ff][Rr][Oo][Mm]([[:space:]]|$)'
from_token_re='^\+[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+((--[^[:space:]]+[[:space:]]+)*)([^[:space:]]+)'
from_alias_re='^[+ ][[:space:]]*[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]]+([^[:space:]]+)[[:space:]]*$'
image_token_re='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'

input=$(cat)

# Empty input → exit 0 with no output
if [ -z "$input" ]; then
  exit 0
fi

# Malformed input detection: here-string (not pipeline) to avoid SIGPIPE
# under pipefail on large valid diffs (issue #50).
if ! grep -qE '^(\+\+\+|---|@@|diff --git)' <<< "$input"; then
  echo "extract-deps.sh: input is not a unified diff" >&2
  exit 2
fi

while IFS= read -r line; do
  # Strip CR for CRLF-encoded diffs
  line="${line%$'\r'}"

  # --- Branch 1: diff --git file header — track current file/ecosystem ---
  if [[ "$line" =~ ^diff[[:space:]]--git[[:space:]]a/([^[:space:]]+)[[:space:]]b/([^[:space:]]+) ]]; then
    current_file="${BASH_REMATCH[2]##*/}"
    current_ecosystem=$(filename_to_ecosystem "$current_file")
    current_name=""
    stage_names=$'\n'
    case "$current_file" in
      Dockerfile|Containerfile|*.Dockerfile|Dockerfile.*) current_is_dockerfile=true ;;
      *) current_is_dockerfile=false ;;
    esac
    continue
  fi

  # Skip diff file headers (+++ b/path)
  [[ "$line" == +++* ]] && continue

  # --- Dockerfile FROM lines (context/+ record stage aliases; + emits rows) ---
  if $current_is_dockerfile; then
    if [[ "$line" =~ $from_alias_re ]]; then
      alias_lc=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
      stage_names="${stage_names}${alias_lc}"$'\n'
    fi
    if [[ "$line" =~ $from_line_re ]]; then
      token=""
      if [[ "$line" =~ $from_token_re ]]; then
        token="${BASH_REMATCH[3]}"
      fi
      token_lc=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')
      [ "$token_lc" = "scratch" ] && continue
      if [ -n "$token" ]; then
        case "$stage_names" in *$'\n'"$token_lc"$'\n'*) continue ;; esac
      fi

      if [ -z "$token" ] || [[ "$token" == *'$'* ]] || ! [[ "$token" =~ $image_token_re ]]; then
        name="${token:-FROM}"
        version="-"
      else
        rest="$token"
        digest=""
        tag=""
        if [[ "$rest" == *@* ]]; then
          digest="${rest##*@}"
          rest="${rest%@*}"
        fi
        if [[ "$rest" == *:* ]] && [[ "${rest##*:}" != */* ]]; then
          tag="${rest##*:}"
          rest="${rest%:*}"
        fi
        name="$rest"
        if [ -n "$tag" ] && [ -n "$digest" ]; then
          version="$tag@$digest"
        elif [ -n "$tag" ]; then
          version="$tag"
        elif [ -n "$digest" ]; then
          version="$digest"
        else
          version="latest"
        fi
      fi
      key="docker:$name@$version"
      case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
      seen="${seen}${key}"$'\n'
      rows+=("$name"$'\t'"$version"$'\t'"docker")
      continue
    fi
  fi

  # --- Branch 3: [[package]] stanza boundary (context or +, not -) ---
  if [ -n "$current_ecosystem" ] && [[ "$line" =~ ^[+\ ][[:space:]]*\[\[package\]\] ]]; then
    current_name=""
    continue
  fi

  # --- Branch 4: name = "..." line (context or +, not -) ---
  if [ -n "$current_ecosystem" ] && [[ "$line" =~ ^[+\ ][[:space:]]*name[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
    current_name="${BASH_REMATCH[1]}"
    continue
  fi

  # --- Branch 5: + version = "..." line (only + lines emit rows) ---
  if [ -n "$current_ecosystem" ] && [ -n "$current_name" ] \
     && [[ "$line" =~ ^\+[[:space:]]*version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
    key="$current_ecosystem:$current_name"
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen="${seen}${key}"$'\n'
    rows+=("$current_name"$'\t'"${BASH_REMATCH[1]}"$'\t'"$current_ecosystem")
    continue
  fi

  # --- GitHub Actions parser (existing, unchanged) ---
  if [[ "$line" =~ ^\+[[:space:]]+(-[[:space:]]+)?uses:[[:space:]]+([^[:space:]@]+)@[^[:space:]]+(.*)$ ]]; then
    name="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"

    [[ "$name" == ./* ]] && continue
    [[ "$name" == docker://* ]] && continue

    version=""
    if [[ "$rest" =~ \#[[:space:]]*v?([0-9][0-9.]*) ]]; then
      version="${BASH_REMATCH[1]}"
    fi

    key="actions:$name"
    case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
    seen="${seen}${key}"$'\n'
    rows+=("$name"$'\t'"$version"$'\t'"actions")
    continue
  fi

  # --- Python deps parser (existing, unchanged) ---
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
