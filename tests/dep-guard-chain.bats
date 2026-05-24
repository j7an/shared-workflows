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

# Mirrors the workflow composition block from §4.3 of the spec, including
# the CLEARED_PYPROJECT subtraction and the EFFECTIVE_TOUCHED computation.
run_chain_with_pyproject() {
  local fixture="$1"
  local diff_content
  diff_content=$(cat "$fixture")

  # Note: extract-deps is invoked here without error suppression to match the
  # workflow's behavior — its failures should surface. The new helper is
  # guarded with `2>/dev/null || true` because exit-2 on malformed input is
  # informational at the integration layer.
  EXTRACTED=$(printf '%s' "$diff_content" | bash scripts/extract-deps.sh)
  PYPROJECT_DEPS=$(printf '%s' "$diff_content" | bash scripts/pyproject-bump-extract.sh --mode=deps 2>/dev/null || true)
  DEPS_TSV=$(printf '%s\n%s\n' "$EXTRACTED" "$PYPROJECT_DEPS" | sed '/^$/d' | sort -u)

  TOUCHED_PATHS=$(printf '%s' "$diff_content" | bash scripts/diff-touches-lockfile.sh 2>/dev/null || true)
  BASE_UNSUPPORTED=$(printf '%s\n' "$TOUCHED_PATHS" | bash scripts/classify-touched-paths.sh 2>/dev/null || true)
  CLEARED_PYPROJECT=$(printf '%s' "$diff_content" | bash scripts/pyproject-bump-extract.sh --mode=cleared-paths 2>/dev/null || true)

  UNSUPPORTED_PATHS="$BASE_UNSUPPORTED"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  if [ -n "$(printf '%s\n' "$CLEARED_PYPROJECT" | sed '/^$/d')" ]; then
    local cleared_file
    cleared_file=$(mktemp "${TMPDIR:-/tmp}/cleared-pyproject-paths.XXXXXX")
    printf '%s\n' "$CLEARED_PYPROJECT" | sed '/^$/d' | sort -u > "$cleared_file"
    UNSUPPORTED_PATHS=$(printf '%s\n' "$BASE_UNSUPPORTED" | sed '/^$/d' | grep -vFxf "$cleared_file" || true)
    EFFECTIVE_TOUCHED=$(printf '%s\n' "$TOUCHED_PATHS" | sed '/^$/d' | grep -vFxf "$cleared_file" || true)
    rm -f "$cleared_file"
  fi
}

@test "pyproject-only Poetry bump — DEPS includes requests, UNSUPPORTED empty (issue #66)" {
  run_chain_with_pyproject "$FIXTURES/pyproject-only.diff"
  [[ "$DEPS_TSV" == *"requests"* ]]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "workflow YAML uses: bump — DEPS_TSV non-empty, UNSUPPORTED empty" {
  run_chain "$FIXTURES/workflow-uses-bump.diff"
  [ -n "$DEPS_TSV" ]
  [[ "$DEPS_TSV" == *"actions/checkout"* ]]
  [ "$TOUCHED_PATHS" = ".github/workflows/ci.yml" ]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "uv pyproject + uv.lock Dependabot bump passes guard (AC1)" {
  run_chain_with_pyproject "$FIXTURES/uv-pyproject-plus-lock.diff"
  [[ "$DEPS_TSV" == *"ruff"* ]]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "poetry pyproject + poetry.lock Dependabot bump passes guard (AC2)" {
  run_chain_with_pyproject "$FIXTURES/poetry-pyproject-plus-lock.diff"
  [[ "$DEPS_TSV" == *"requests"* ]]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "pyproject-only supported bump extracts and clears" {
  run_chain_with_pyproject "$FIXTURES/uv-pyproject-only-bump.diff"
  [[ "$DEPS_TSV" == *"ruff"* ]]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "pyproject non-bump edit remains fail-loud (AC3)" {
  run_chain_with_pyproject "$FIXTURES/pyproject-add-dep.diff"
  # pyproject contributes no rows; if other helpers also produce none, DEPS is empty.
  # The critical assertion is UNSUPPORTED still contains pyproject.toml.
  [[ "$UNSUPPORTED_PATHS" == *"pyproject.toml"* ]]
}

@test "mixed: cleared pyproject + unsupported package-lock.json" {
  run_chain_with_pyproject "$FIXTURES/pyproject-bump-plus-npm.diff"
  [[ "$DEPS_TSV" == *"ruff"* ]]
  [[ "$UNSUPPORTED_PATHS" == *"package-lock.json"* ]]
}

@test "pyproject disqualifier + uv.lock bump preserves AC4 fail-loud" {
  run_chain_with_pyproject "$FIXTURES/pyproject-add-dep-plus-uvlock.diff"
  # uv.lock contributes newpkg row from extract-deps.
  [[ "$DEPS_TSV" == *"newpkg"* ]]
  # pyproject still flagged unsupported.
  [[ "$UNSUPPORTED_PATHS" == *"pyproject.toml"* ]]
}

@test "cross-helper dedup: same package in pyproject + uv.lock yields one row" {
  run_chain_with_pyproject "$FIXTURES/cross-helper-dedup.diff"
  # Count ruff rows in DEPS_TSV.
  ruff_rows=$(printf '%s\n' "$DEPS_TSV" | grep -c $'^ruff\t' || true)
  [ "$ruff_rows" -eq 1 ]
  [ -z "$UNSUPPORTED_PATHS" ]
}

@test "comment-only pyproject does NOT trip Layer 3 zero-row guard" {
  run_chain_with_pyproject "$FIXTURES/pyproject-comment-only.diff"
  [ -z "$(echo "$DEPS_TSV" | sed '/^$/d')" ]
  [ -z "$UNSUPPORTED_PATHS" ]
  [ -z "$EFFECTIVE_TOUCHED" ]
}
