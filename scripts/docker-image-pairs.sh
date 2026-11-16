#!/usr/bin/env bash
# docker-image-pairs.sh — pair removed and added Dockerfile FROM images from a
# unified diff on stdin.
#
# Output: <file path>\t<old name>\t<old version>\t<new name>\t<new version>\t<status>
#   One row per added, non-skipped, parseable FROM line, in file order.
#   name/version split exactly as extract-deps.sh does; version is one of
#   tag@digest | tag | digest | latest.
#   status:
#     ok                    removed FROM paired with the added FROM by position
#     pairing-ambiguous     no removed FROM, or removed/added FROM counts differ
#                           within one file (every added row in that file)
#     unparseable-reference the paired removed FROM could not be parsed
#   On non-ok status the old name/version fields are "-".
#   An unparseable ADDED FROM emits no row: extract-deps.sh already emits its
#   "-" marker row, and the consumer reports that image as missing-comparison.
#   `FROM scratch` and `FROM <earlier stage alias>` are skipped on both sides.
# Exit:   0 on success (possibly zero rows), 2 when non-empty input is not a
#         unified diff
#
# The from_*_re regexes, the scratch/stage-name skip and the name/version split
# MUST stay identical to scripts/extract-deps.sh (tests/docker-image-pairs.bats
# has a parity test). Bash 3.2 compatible: no associative arrays.

set -euo pipefail

from_line_re='^\+[[:space:]]*[Ff][Rr][Oo][Mm]([[:space:]]|$)'
from_token_re='^\+[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+((--[^[:space:]]+[[:space:]]+)*)([^[:space:]]+)'
from_alias_re='^[+ ][[:space:]]*[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]]+([^[:space:]]+)[[:space:]]*$'
image_token_re='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'

current_file=""
current_path=""
current_is_dockerfile=false
# Stage names per side: removed side = context + '-' lines; added side = context + '+' lines.
stage_old=$'\n'
stage_new=$'\n'
# Per-file refs: "name<TAB>version", or "-" for an unparseable reference.
old_refs=()
new_refs=()
old_n=0
new_n=0

flush_file() {
  local i status ostr
  if $current_is_dockerfile && [ "$new_n" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$new_n" ]; do
      if [ "${new_refs[$i]}" != "-" ]; then
        if [ "$old_n" -ne "$new_n" ]; then
          status="pairing-ambiguous"
          ostr="-"$'\t'"-"
        elif [ "${old_refs[$i]}" = "-" ]; then
          status="unparseable-reference"
          ostr="-"$'\t'"-"
        else
          status="ok"
          ostr="${old_refs[$i]}"
        fi
        printf '%s\t%s\t%s\t%s\n' "$current_path" "$ostr" "${new_refs[$i]}" "$status"
      fi
      i=$((i + 1))
    done
  fi
  old_refs=()
  new_refs=()
  old_n=0
  new_n=0
}

input=$(cat)

if [ -z "$input" ]; then
  exit 0
fi

if ! grep -qE '^(\+\+\+|---|@@|diff --git)' <<< "$input"; then
  echo "docker-image-pairs.sh: input is not a unified diff" >&2
  exit 2
fi

while IFS= read -r line; do
  line="${line%$'\r'}"

  if [[ "$line" =~ ^diff[[:space:]]--git[[:space:]]a/([^[:space:]]+)[[:space:]]b/([^[:space:]]+) ]]; then
    flush_file
    current_path="${BASH_REMATCH[2]}"
    current_file="${current_path##*/}"
    stage_old=$'\n'
    stage_new=$'\n'
    case "$current_file" in
      Dockerfile|Containerfile|*.Dockerfile|Dockerfile.*) current_is_dockerfile=true ;;
      *) current_is_dockerfile=false ;;
    esac
    continue
  fi

  $current_is_dockerfile || continue
  [[ "$line" == +++\ * || "$line" == ---\ * ]] && continue

  side="${line:0:1}"
  case "$side" in
    ' '|'+'|'-') ;;
    *) continue ;;
  esac
  # Normalise to a '+' line so the extract-deps.sh regexes apply unchanged.
  norm="+${line:1}"

  if [ "$side" = "-" ]; then
    prev_stage_names="$stage_old"
  elif [ "$side" = "+" ]; then
    prev_stage_names="$stage_new"
  else
    prev_stage_names="$stage_new"
  fi

  if [[ "$norm" =~ $from_alias_re ]]; then
    alias_lc=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    if [ "$side" != "+" ]; then stage_old="${stage_old}${alias_lc}"$'\n'; fi
    if [ "$side" != "-" ]; then stage_new="${stage_new}${alias_lc}"$'\n'; fi
  fi

  [ "$side" = " " ] && continue

  if [[ "$norm" =~ $from_line_re ]]; then
    token=""
    if [[ "$norm" =~ $from_token_re ]]; then
      token="${BASH_REMATCH[3]}"
    fi
    token_lc=$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')
    [ "$token_lc" = "scratch" ] && continue
    if [ -n "$token" ]; then
      case "$prev_stage_names" in *$'\n'"$token_lc"$'\n'*) continue ;; esac
    fi

    if [ -z "$token" ] || [[ "$token" == *'$'* ]] || ! [[ "$token" =~ $image_token_re ]]; then
      ref="-"
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
      ref="$name"$'\t'"$version"
    fi

    if [ "$side" = "-" ]; then
      old_refs[$old_n]="$ref"
      old_n=$((old_n + 1))
    else
      new_refs[$new_n]="$ref"
      new_n=$((new_n + 1))
    fi
  fi
done <<< "$input"

flush_file
