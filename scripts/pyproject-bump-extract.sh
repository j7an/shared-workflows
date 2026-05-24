#!/usr/bin/env bash
# pyproject-bump-extract.sh — diff-aware extractor for pyproject.toml bump-only edits.
#
# Owns all pyproject.toml diff semantics for the dependency-cooldown/safety
# workflows. Recognizes the narrow set of bump shapes Dependabot emits for
# uv/poetry ecosystems and emits either extracted dep rows (mode=deps) or
# the paths it proved are bump-only (mode=cleared-paths). Files with any
# unparseable changed line (build-system edits, new-dep additions, marker
# changes, etc.) are disqualified and left unsupported so the existing
# fail-loud guard fires.
#
# Input:  unified diff on stdin
# Flag:   --mode=deps  OR  --mode=cleared-paths  (exactly one, required)
# Output (deps):          TSV <name>\t<version>\tpypi, sorted by name, deduped
# Output (cleared-paths): newline-delimited pyproject.toml paths, sorted, deduped
# Exit:   0 on success (possibly zero rows / zero paths)
#         2 on malformed input, missing --mode, unknown mode, or repeated --mode
#
# Bash 3.2 compatible: no `declare -A`, no `mapfile`/`readarray`. Dedup uses a
# newline-delimited string sentinel, matching scripts/extract-deps.sh.
#
# See docs/superpowers/specs/2026-05-23-pyproject-toml-parser-design.md.

set -euo pipefail

MODE=""
for arg in "$@"; do
  case "$arg" in
    --mode=deps|--mode=cleared-paths)
      if [ -n "$MODE" ]; then
        echo "pyproject-bump-extract.sh: --mode specified more than once" >&2
        exit 2
      fi
      MODE="${arg#--mode=}"
      ;;
    *)
      echo "pyproject-bump-extract.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "pyproject-bump-extract.sh: --mode=deps or --mode=cleared-paths required" >&2
  exit 2
fi

input=$(cat)

# Empty input → exit 0 with no output (matches extract-deps.sh).
if [ -z "$input" ]; then
  exit 0
fi

# Malformed input detection: here-string (not pipeline) to avoid SIGPIPE under
# pipefail on large valid diffs (issue #50 pattern).
if ! grep -qE '^(\+\+\+|---|@@|diff --git)' <<< "$input"; then
  echo "pyproject-bump-extract.sh: input is not a unified diff" >&2
  exit 2
fi

# Parser state (filled in by subsequent tasks). For now, no recognition logic;
# every diff with no pyproject.toml hunks correctly yields zero output.
exit 0
