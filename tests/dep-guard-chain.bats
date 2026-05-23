#!/usr/bin/env bats
# dep-guard-chain.bats — integration tests for the Layer 2/3 guard composition.
#
# These tests drive the real helper chain (extract-deps + diff-touches-lockfile
# + classify-touched-paths) against canned diff fixtures and assert the values
# the workflow guard keys on: DEPS_TSV (extracted dep rows), TOUCHED_PATHS
# (dependency-relevant files in the diff), and UNSUPPORTED_PATHS (the subset
# extract-deps cannot parse).
#
# Workflow YAML execution is not exercised here; tests/guard-shape.bats guards
# the YAML control flow statically.

setup() {
  FIXTURES="tests/fixtures/dep-guard-chain"
}

# Helper: run the chain on a fixture file and export the three intermediate
# values into the test's environment.
run_chain() {
  local fixture="$1"
  DEPS_TSV=$(bash scripts/extract-deps.sh < "$fixture" || true)
  TOUCHED_PATHS=$(bash scripts/diff-touches-lockfile.sh < "$fixture" 2>/dev/null || true)
  UNSUPPORTED_PATHS=$(printf '%s\n' "$TOUCHED_PATHS" | bash scripts/classify-touched-paths.sh 2>/dev/null || true)
}

@test "issue #62 repro: uv.lock + package-lock.json — DEPS_TSV non-empty, UNSUPPORTED contains package-lock.json" {
  run_chain "$FIXTURES/uv-and-package-lock.diff"
  # DEPS_TSV has the uv.lock row (mypy 1.20.1 pypi).
  [ -n "$DEPS_TSV" ]
  [[ "$DEPS_TSV" == *"mypy"* ]]
  # TOUCHED_PATHS includes both files.
  [[ "$TOUCHED_PATHS" == *"uv.lock"* ]]
  [[ "$TOUCHED_PATHS" == *"package-lock.json"* ]]
  # UNSUPPORTED_PATHS contains ONLY package-lock.json.
  [ "$UNSUPPORTED_PATHS" = "package-lock.json" ]
}

@test "issue #52 preserved: uv.lock parser miss — DEPS_TSV empty, TOUCHED=uv.lock, UNSUPPORTED empty" {
  run_chain "$FIXTURES/uv-lock-parser-miss.diff"
  [ -z "$DEPS_TSV" ]
  [ "$TOUCHED_PATHS" = "uv.lock" ]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "requirements.txt standard bump — DEPS_TSV non-empty, UNSUPPORTED empty" {
  run_chain "$FIXTURES/requirements-bump.diff"
  [ -n "$DEPS_TSV" ]
  [[ "$DEPS_TSV" == *"requests"* ]]
  [ "$TOUCHED_PATHS" = "requirements.txt" ]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "pyproject.toml only — TOUCHED=pyproject.toml, UNSUPPORTED=pyproject.toml" {
  run_chain "$FIXTURES/pyproject-only.diff"
  [ "$TOUCHED_PATHS" = "pyproject.toml" ]
  [ "$UNSUPPORTED_PATHS" = "pyproject.toml" ]
}

@test "workflow YAML uses: bump — DEPS_TSV non-empty, UNSUPPORTED empty" {
  run_chain "$FIXTURES/workflow-uses-bump.diff"
  [ -n "$DEPS_TSV" ]
  [[ "$DEPS_TSV" == *"actions/checkout"* ]]
  [ "$TOUCHED_PATHS" = ".github/workflows/ci.yml" ]
  [ -z "$UNSUPPORTED_PATHS" ]
}
