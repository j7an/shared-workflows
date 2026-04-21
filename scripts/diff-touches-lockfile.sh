#!/usr/bin/env bash
# diff-touches-lockfile.sh — detect dependency lockfile/manifest edits in a
# unified diff. Used by dependency-cooldown.yml's fail-loud guard to refuse
# green gates when the dep extractor returns zero rows on a lockfile bump.
#
# Input:  unified diff on stdin
# Output: matched paths (b/ side of diff --git headers), sorted & deduped,
#         one per line; empty stdout if nothing matched.
# Exit:   0 if any lockfile/manifest touched, 1 if none, 2 on malformed input.

set -euo pipefail

input=$(cat)

if [ -z "$input" ]; then
  exit 1
fi

if ! grep -qE '^diff --git ' <<< "$input"; then
  echo "diff-touches-lockfile.sh: input is not a unified diff" >&2
  exit 2
fi

matches=()
while IFS= read -r path; do
  base="${path##*/}"
  # Add new lockfile/manifest filename patterns to this case list as needed.
  case "$base" in
    *.lock|requirements*.txt|pyproject.toml|Pipfile|go.mod|Cargo.toml \
      |package.json|package-lock.json|yarn.lock|pnpm-lock.yaml)
      matches+=("$path")
      ;;
  esac
done < <(grep -oE '^diff --git a/[^ ]+ b/[^ ]+' <<< "$input" \
         | sed -E 's|^diff --git a/[^ ]+ b/||')

if [ ${#matches[@]} -eq 0 ]; then
  exit 1
fi

printf '%s\n' "${matches[@]}" | sort -u
