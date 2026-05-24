#!/usr/bin/env bash
# classify-touched-paths.sh — filter dependency-relevant paths down to
# those that extract-deps.sh does NOT parse.
#
# Input:  newline-delimited paths on stdin (typically the output of
#         diff-touches-lockfile.sh).
# Output: subset of input paths whose filename/location is NOT in the
#         extract-deps.sh supported set, sorted & deduped, one per line.
#         Empty stdout when every input path is supported.
# Exit:   0 on success (zero or more output rows). No exit-2 path: malformed
#         input here is "an unrecognised filename" which is exactly what we
#         report on stdout.
#
# Supported set (must stay in sync with scripts/extract-deps.sh):
#   - .github/workflows/*.yml | *.yaml  (GitHub Actions `uses:` line parser)
#   - uv.lock | poetry.lock             (TOML [[package]] stanza parser)
#   - requirements*.txt                 (pip line-shape parser)
#
# `requirements*.txt` is supported by line-shape parsing, not by a full
# requirements-file parser. The extractor recognizes added requirement lines
# with operators ==, >=, <=, ~=, !=, >, or < and a numeric version prefix;
# comments, includes like `-r other.txt`, hash/check option lines, and other
# requirements-file structure are ignored. Standard Dependabot bumps reliably
# surface as added pinned requirement lines, which is what we promise.
#
# Everything else diff-touches-lockfile.sh emits — pyproject.toml, Pipfile,
# Pipfile.lock, go.mod, Cargo.toml, Cargo.lock, package.json,
# package-lock.json, yarn.lock, pnpm-lock.yaml, and any other *.lock — is
# unsupported and printed to stdout. Layer 2 (PR-body fallback) may still
# recover deps from some of these for the scan loop, but the guard fires
# because the diff parser cannot prove the scan was complete.
#
# pyproject.toml is path-level unsupported here and may be cleared by
# scripts/pyproject-bump-extract.sh at the workflow composition layer
# when its hunks are proven to be bump-only. This script remains
# path-only and intentionally conservative; the final unsupported set
# in the workflow is produced by composition, not by this classifier
# alone.

set -euo pipefail

while IFS= read -r path || [ -n "$path" ]; do
  [ -z "$path" ] && continue
  base="${path##*/}"

  # Supported (drop from output).
  case "$path" in
    .github/workflows/*.yml|.github/workflows/*.yaml) continue ;;
  esac
  case "$base" in
    uv.lock|poetry.lock) continue ;;
    requirements*.txt)   continue ;;
  esac

  # Anything else: emit as unsupported.
  printf '%s\n' "$path"
done | sort -u
