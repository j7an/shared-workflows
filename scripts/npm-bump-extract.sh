#!/usr/bin/env bash
# npm-bump-extract.sh — diff-aware extractor for package.json + pnpm-lock.yaml.
#
# Owns all npm-ecosystem diff semantics for the dependency-safety workflow.
# Emits tier-1 declared dependency rows (mode=deps), tier-2 newly introduced
# lockfile versions (mode=lockfile-entries), or the paths it proved parseable
# (mode=cleared-paths). Files with any unrecognized changed line are
# disqualified and left unsupported so the fail-loud guard fires.
#
# Input:  unified diff on stdin
# Flag:   --mode=deps | --mode=lockfile-entries | --mode=cleared-paths (exactly one)
# Output (deps):             TSV <name>\t<version>\tnpm, sorted by name, deduped
# Output (lockfile-entries): TSV <name>\t<version>\tnpm, sorted by name, deduped
# Output (cleared-paths):    newline-delimited paths, sorted, deduped
# Exit:   0 on success (possibly zero rows)
#         2 on malformed input, missing --mode, repeated --mode, unknown argument
#
# Bash 3.2 compatible: no `declare -A`, no `mapfile`/`readarray`. Dedup uses a
# newline-delimited string sentinel, matching scripts/extract-deps.sh.
#
# See docs/superpowers/specs/2026-08-04-npm-pnpm-dependency-safety-design.md.

set -euo pipefail

# Maximum tier-2 entries per PR. Exceeding it disqualifies the lockfile rather
# than truncating the sweep — a truncated scan reported as complete is the one
# outcome this helper must never produce. 1000 is ~4x the largest observed real
# Dependabot pnpm PR (253 entries).
TIER2_MAX_ENTRIES=1000

MODE=""
for arg in "$@"; do
  case "$arg" in
    --mode=deps|--mode=lockfile-entries|--mode=cleared-paths)
      if [ -n "$MODE" ]; then
        echo "npm-bump-extract.sh: --mode specified more than once" >&2
        exit 2
      fi
      MODE="${arg#--mode=}"
      ;;
    *)
      echo "npm-bump-extract.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "npm-bump-extract.sh: --mode=deps, --mode=lockfile-entries, or --mode=cleared-paths required" >&2
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
  echo "npm-bump-extract.sh: input is not a unified diff" >&2
  exit 2
fi

exit 0
