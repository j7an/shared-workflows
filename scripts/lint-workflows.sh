#!/usr/bin/env bash
# lint-workflows.sh — structural workflow linting in the known non-hanging mode.
#
# Default `actionlint` (ShellCheck integration on) HANGS on
# .github/workflows/dependency-safety.yml: its large inlined `Scan and report`
# block interacts badly with actionlint's ShellCheck orchestration. This is a
# tool limitation, not a workflow syntax error, and is pre-existing on main
# (see issue #81). Disabling the ShellCheck and Pyflakes integrations makes
# structural linting complete deterministically:
#
#   actionlint -shellcheck= -pyflakes= .github/workflows/*.yml
#
# ShellCheck is a SEPARATE, optional signal — run `shellcheck scripts/*.sh`
# when useful (it has known info-level findings; not this command's concern).
#
# Usage: ./scripts/lint-workflows.sh [workflow-file ...]
#   No args  -> lints .github/workflows/*.yml
#   Args     -> workflow FILE PATHS only (e.g. lint a single file)
# The -shellcheck= / -pyflakes= flags are fixed and cannot be overridden;
# any flag-like argument is rejected so this stays the reliable command.
#
# Exit: actionlint's exit code (0 = clean, non-zero = findings);
#       2   if a flag-like argument is passed;
#       127 if actionlint is not installed.

set -euo pipefail

# Reject flag-like arguments: callers may pass workflow file paths only.
for arg in "$@"; do
  case "$arg" in
    -*)
      echo "lint-workflows.sh: arguments must be workflow file paths, not flags: '$arg'" >&2
      echo "The -shellcheck= and -pyflakes= flags are fixed and cannot be overridden." >&2
      exit 2
      ;;
  esac
done

if ! command -v actionlint >/dev/null 2>&1; then
  echo "lint-workflows.sh: actionlint not found on PATH." >&2
  echo "Install it (e.g. 'brew install actionlint') or see https://github.com/rhysd/actionlint" >&2
  exit 127
fi

if [ "$#" -gt 0 ]; then
  exec actionlint -shellcheck= -pyflakes= "$@"
else
  exec actionlint -shellcheck= -pyflakes= .github/workflows/*.yml
fi
