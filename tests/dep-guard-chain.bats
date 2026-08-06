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

# Extract a sentinel-delimited block from a workflow `run: |` body and strip the
# 10-space YAML indent, leaving plain bash. Mirrors extract_guard_block in
# tests/guard-runtime.bats.
extract_named_block() {
  local yaml="$1" name="$2"
  awk -v n="$name" '
    $0 ~ ("# --- BEGIN " n " ---") {flag=1; next}
    $0 ~ ("# --- END " n " ---")   {exit}
    flag {print}
  ' "$yaml" | sed -E 's/^          //'
}
WF=.github/workflows/dependency-safety.yml
NPMFX=tests/fixtures/npm-bump-extract

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

# ---------------------------------------------------------------------------
# Runtime coverage for the composed npm pipeline.
#
# Everything above re-implements the composition in the test harness. The cases
# below eval the REAL workflow bash, extracted from dependency-safety.yml
# between its sentinels, so a composition defect (a dropped subtraction, a
# missing conjunct, an unvalidated response) surfaces as a red test instead of
# hiding behind a parallel implementation that happens to agree.
#
# Every `[[ ... ]]` below carries an explicit `|| return 1`. bash 3.2 — the
# version this repo targets and the one macOS ships — does NOT apply `set -e`
# to a failing `[[ ]]`, so a bare mid-body `[[ ]]` assertion is a silent no-op
# locally and only turns red on CI's newer bash. `|| return 1` makes every
# assertion binding under both.
# ---------------------------------------------------------------------------

# Drive the real `npm composition` block over a fixture diff.
# $1 = fixture path, $2 = optional PR body.
#
# Seeds ONLY the block's free inputs: $DIFF, $PR_BODY, and shims for the six
# helper functions the workflow step defines above the block. DEPS_TSV,
# NPM_DEPS_TSV, CLEARED_NPM, CLEARED_ALL, BASE_UNSUPPORTED, UNSUPPORTED_PATHS,
# EFFECTIVE_TOUCHED and ECO_HINT are all COMPUTED here — pre-seeding any of them
# would be dead code the block immediately overwrites. `set -u` makes the driver
# self-checking: a forgotten input aborts with `unbound variable` rather than
# letting the case pass vacuously.
run_npm_chain() {
  local fixture="$1" pr_body="${2:-}"
  local block; block=$(extract_named_block "$WF" "npm composition")
  run bash -c "
    set -uo pipefail
    extract_deps()           { bash scripts/extract-deps.sh \"\$@\"; }
    diff_touches_lockfile()  { bash scripts/diff-touches-lockfile.sh \"\$@\"; }
    classify_touched_paths() { bash scripts/classify-touched-paths.sh \"\$@\"; }
    pyproject_bump_extract() { bash scripts/pyproject-bump-extract.sh \"\$@\"; }
    pr_body_to_deps()        { bash scripts/pr-body-to-deps.sh \"\$@\"; }
    npm_bump_extract()       { bash scripts/npm-bump-extract.sh \"\$@\"; }
    DIFF=\$(cat '$fixture')
    PR_BODY='$pr_body'
    $block
    printf 'DEPS=[%s]\n'  \"\$DEPS_TSV\"
    printf 'UNSUP=[%s]\n' \"\$UNSUPPORTED_PATHS\"
    printf 'EFF=[%s]\n'   \"\$EFFECTIVE_TOUCHED\"
    printf 'HINT=[%s]\n'  \"\${ECO_HINT:-}\"
  "
}
# ECO_HINT is printed through ${ECO_HINT:-} on purpose: the workflow only
# assigns it inside `if [ -z "$DEPS_TSV" ]`, so on a clean bump it is never set
# and a bare "$ECO_HINT" would abort the case under `set -u`.

@test "npm chain: clean bump produces tier-1 rows and clears its paths" {
  run_npm_chain "$NPMFX/manifest-and-lock-clean.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"@commitlint/cli"* ]] || return 1
  [[ "$output" == *"UNSUP=[]"* ]] || return 1
}

@test "npm chain: disqualified manifest triggers the guard" {
  run_npm_chain "$NPMFX/manifest-postinstall.diff"
  [ "$status" -eq 0 ]
  # The helper failed closed, so nothing is cleared and both paths remain.
  [[ "$output" == *"package.json"* ]] || return 1
  [[ "$output" == *"pnpm-lock.yaml"* ]] || return 1
}

@test "npm chain: lockfile-only security update goes green" {
  run_npm_chain "$NPMFX/real-lockfile-only.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPS=[]"* ]] || return 1
  [[ "$output" == *"UNSUP=[]"* ]] || return 1
}

@test "npm chain: cleared paths are subtracted from BOTH guard inputs" {
  run_npm_chain "$FIXTURES/npm-clean-plus-gemfile.diff"
  [ "$status" -eq 0 ]
  # Gemfile.lock survives in both sets; the two npm paths survive in neither.
  [[ "$output" == *"UNSUP=[Gemfile.lock]"* ]] || return 1
  [[ "$output" == *"EFF=[Gemfile.lock]"* ]] || return 1
  [[ "$output" != *"package.json"* ]] || return 1
}

@test "npm chain: body fallback is suppressed when the helper cleared paths" {
  # A PR body that WOULD yield rows if the fallback were reachable.
  run_npm_chain "$NPMFX/real-lockfile-only.diff" \
    "Bumps [lodash](https://github.com/lodash/lodash) from 4.17.20 to 4.17.21."
  [ "$status" -eq 0 ]
  # Zero rows plus a cleared lockfile is a PROVEN empty result, not missing
  # evidence — promoting PR-body prose here would contradict lockfile authority.
  [[ "$output" == *"HINT=[]"* ]] || return 1
  [[ "$output" == *"DEPS=[]"* ]] || return 1
}

# --- dep routing -------------------------------------------------------------
#
# The `dep routing` block partitions $DEPS_TSV into ACTIONS/PY_DEPS/NPM_ROWS by
# the third (ecosystem) column. NPM_ROWS is the sole producer consumed by the
# tier-1 npm scan loop below (`while IFS=$'\t' read -r PKG _npm_ver`), so this
# also pins the two-field "name<TAB>version" row shape that consumer depends
# on. ACTIONS/PY_DEPS/NPM_ROWS are all assigned fresh at the top of the block,
# so DEPS_TSV is the only free input to seed.
#
# ACTION_VERSIONS/PY_VERSIONS are declared `-A` by the real step (line ~1875,
# above this block) before it runs — that's a real precondition, not something
# this block establishes itself, so the driver declares it too. `declare -A`
# needs bash >= 4; this repo's dev tests run on macOS system bash (3.2), which
# has no associative arrays at all. The actions/pypi row NAMEs below are
# deliberately single alphanumeric words (no `/`, `-`, `.`) so that on bash 3.2
# — where `declare -A` fails and the assignment silently falls back to a
# plain indexed array — the unset-bareword-as-0 arithmetic subscript bash 3.2
# uses is at least internally consistent between write and any (unused) read,
# and never hits the "division by 0" parse error a realistic `owner/repo`
# action name would trigger. Real CI (ubuntu-latest) has bash 5, where
# `declare -A` succeeds and the arrays are genuinely associative. Either way,
# NPM_ROWS itself is a plain string variable untouched by this limitation.
run_dep_routing() {
  local tsv_file="$1"
  local block; block=$(extract_named_block "$WF" "dep routing")
  run bash -c "
    set -o pipefail
    declare -A ACTION_VERSIONS PY_VERSIONS 2>/dev/null || true
    DEPS_TSV=\$(cat '$tsv_file')
    $block
    printf 'NPM_LINES=%s\n' \"\$(printf '%s\n' \"\$NPM_ROWS\" | sed '/^\$/d' | wc -l | tr -d ' ')\"
    printf 'NPM_ROWS<<<%s>>>\n' \"\$NPM_ROWS\"
  "
}

@test "dep routing: NPM_ROWS contains exactly the npm rows as name<TAB>version" {
  local tsv="$BATS_TEST_TMPDIR/deps.tsv"
  printf 'sampleaction\tv1\tactions\nsamplepkg\t2.0.0\tpypi\nleftpad\t1.0.0\tnpm\nlodash\t4.17.21\tnpm\n' > "$tsv"
  run_dep_routing "$tsv"
  [ "$status" -eq 0 ] || return 1
  # Exactly 2 lines: no actions/pypi bleed-through, no duplication.
  [[ "$output" == *"NPM_LINES=2"* ]] || return 1
  [[ "$output" == *$'leftpad\t1.0.0'* ]] || return 1
  [[ "$output" == *$'lodash\t4.17.21'* ]] || return 1
  [[ "$output" != *"sampleaction"* ]] || return 1
  [[ "$output" != *"samplepkg"* ]] || return 1
}

@test "dep routing: no npm rows in DEPS_TSV leaves NPM_ROWS empty" {
  local tsv="$BATS_TEST_TMPDIR/deps-no-npm.tsv"
  printf 'sampleaction\tv1\tactions\nsamplepkg\t2.0.0\tpypi\n' > "$tsv"
  run_dep_routing "$tsv"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"NPM_LINES=0"* ]] || return 1
  [[ "$output" == *"NPM_ROWS<<<>>>"* ]] || return 1
}

# --- tier-2 sweep ----------------------------------------------------------
#
# The `tier-2 sweep` block computes TIER2_TSV and TIER2_COUNT itself, from
# $DIFF via npm_bump_extract, so those are OUTPUTS and are not seeded here
# either. The block's free inputs are $DIFF, the npm_bump_extract shim, the two
# offline fixture seams, and the four accumulators the surrounding step owns
# (OSV_TOTAL, SCAN_ERROR_COUNT, HAS_ERROR, TIER2_SECTION).
#
# BOTH seams are always set so NO case can reach the network: OSV_BATCH_FIXTURE
# covers the querybatch POST, OSV_DETAIL_FIXTURE_DIR covers the per-advisory
# GET. Both mirror AGE_FIXTURE_DIR in check-release-age.sh.
#
# $1 = batch JSON, $2 = fixture diff (default: one tier-2 entry).
run_sweep() {
  local batch_json="$1"
  local fixture="${2:-$NPMFX/real-lockfile-only.diff}"
  local block; block=$(extract_named_block "$WF" "tier-2 sweep")
  printf '%s' "$batch_json" > "$BATS_TEST_TMPDIR/batch.json"
  mkdir -p "$BATS_TEST_TMPDIR/details"
  printf '{"id":"GHSA-aaaa","summary":"test advisory","database_specific":{"severity":"HIGH"}}' \
    > "$BATS_TEST_TMPDIR/details/GHSA-aaaa.json"
  run bash -c "
    set -uo pipefail
    npm_bump_extract() { bash scripts/npm-bump-extract.sh \"\$@\"; }
    DIFF=\$(cat '$fixture')
    OSV_BATCH_FIXTURE='$BATS_TEST_TMPDIR/batch.json'
    OSV_DETAIL_FIXTURE_DIR='$BATS_TEST_TMPDIR/details'
    OSV_TOTAL=0
    SCAN_ERROR_COUNT=0
    HAS_ERROR=false
    TIER2_SECTION=''
    $block
    printf 'ERRC=%s HAS_ERROR=%s OSV_TOTAL=%s TIER2_COUNT=%s\n' \\
      \"\$SCAN_ERROR_COUNT\" \"\$HAS_ERROR\" \"\$OSV_TOTAL\" \"\$TIER2_COUNT\"
    printf 'SECTION<<%s>>\n' \"\$TIER2_SECTION\"
  "
}

@test "tier-2 sweep block extracts non-empty from the workflow" {
  # Guards the driver itself: if the sentinels are renamed or removed, every
  # sweep case below would eval an empty block and could pass vacuously.
  local block; block=$(extract_named_block "$WF" "tier-2 sweep")
  [ -n "$block" ]
  [[ "$block" == *"querybatch"* ]] || return 1
  local npm_block; npm_block=$(extract_named_block "$WF" "npm composition")
  [ -n "$npm_block" ]
  [[ "$npm_block" == *"CLEARED_NPM"* ]] || return 1
}

@test "tier-2 every extracted lockfile entry is queried" {
  # The chunk the sweep sends must cover EVERY row the extractor produced. An
  # undercount silently leaves package versions unscanned while the section
  # still reports the sweep as complete.
  run_sweep '{"results":[{},{}]}' "$NPMFX/lock-packages-added.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIER2_COUNT=2"* ]] || return 1
  [[ "$output" == *"ERRC=0"* ]] || return 1
  [[ "$output" == *"2 new package version(s)"* ]] || return 1
}

@test "tier-2 advisory raises OSV_TOTAL and reaches the rendered section" {
  run_sweep '{"results":[{"vulns":[{"id":"GHSA-aaaa","modified":"2026-01-01T00:00:00Z"}]}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OSV_TOTAL=1"* ]] || return 1
  [[ "$output" == *"ERRC=0"* ]] || return 1
  [[ "$output" == *"GHSA-aaaa"* ]] || return 1
  # The advisory row must name the package the hit index maps back to.
  [[ "$output" == *"minimist"* ]] || return 1
  # OSV_TOTAL feeds TOTAL -> ADVISORY_COUNT, which is what suppresses auto-merge.
  # That link is deliberately NOT asserted here: the verdict call sits outside
  # the `tier-2 sweep` sentinel, and tests/safety-verdict.bats already owns
  # "advisory finding only -> auto_merge_ok=false".
}

@test "tier-2 clean batch reports zero advisories without error" {
  run_sweep '{"results":[{}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"OSV_TOTAL=0"* ]] || return 1
  [[ "$output" == *"ERRC=0"* ]] || return 1
  [[ "$output" == *"0 advisories"* ]] || return 1
}

@test "tier-2 batch request failure raises SCAN_ERROR_COUNT" {
  # Point the seam at a path that does not exist — the read fails like a curl
  # failure would.
  local block; block=$(extract_named_block "$WF" "tier-2 sweep")
  run bash -c "
    set -uo pipefail
    npm_bump_extract() { bash scripts/npm-bump-extract.sh \"\$@\"; }
    DIFF=\$(cat '$NPMFX/real-lockfile-only.diff')
    OSV_BATCH_FIXTURE='$BATS_TEST_TMPDIR/does-not-exist.json'
    OSV_DETAIL_FIXTURE_DIR='$BATS_TEST_TMPDIR/details'
    OSV_TOTAL=0; SCAN_ERROR_COUNT=0; HAS_ERROR=false; TIER2_SECTION=''
    $block
    printf 'ERRC=%s HAS_ERROR=%s\n' \"\$SCAN_ERROR_COUNT\" \"\$HAS_ERROR\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"HAS_ERROR=true"* ]] || return 1
}

@test "tier-2 malformed batch JSON is NOT reported as zero advisories" {
  run_sweep 'this is not json'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"HAS_ERROR=true"* ]] || return 1
  [[ "$output" != *"0 advisories"* ]] || return 1
}

@test "tier-2 cardinality mismatch raises SCAN_ERROR_COUNT" {
  # Two packages queried, one result returned.
  run_sweep '{"results":[{}]}' "$NPMFX/lock-packages-added.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIER2_COUNT=2"* ]] || return 1
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"HAS_ERROR=true"* ]] || return 1
  [[ "$output" != *"0 advisories"* ]] || return 1
}

@test "tier-2 next_page_token raises SCAN_ERROR_COUNT" {
  run_sweep '{"results":[{"next_page_token":"abc123"}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"HAS_ERROR=true"* ]] || return 1
}

@test "tier-2 malformed result member is NOT reported as zero advisories" {
  # A non-array `vulns` must fail closed rather than degrade to "no hits".
  run_sweep '{"results":[{"vulns":"not-an-array"}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"HAS_ERROR=true"* ]] || return 1
  [[ "$output" != *"0 advisories"* ]] || return 1
}

@test "tier-2 empty-string advisory id is NOT reported as zero advisories" {
  # `map(.id)` on [{"id":""}] yields [""], whose length is 1 (> 0), so a
  # naive "any non-empty ids array" check passes; `ids` then becomes the
  # empty string and `for vid in $ids` iterates zero times, silently
  # dropping a real advisory. Validation check 4 (previously mislabeled 5)
  # exists specifically to catch this: every vuln's `.id` must be a
  # non-empty string, not merely present.
  run_sweep '{"results":[{"vulns":[{"id":""}]}]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"HAS_ERROR=true"* ]] || return 1
  [[ "$output" != *"0 advisories"* ]] || return 1
}

@test "tier-2 malformed advisory detail is NOT published as an empty row" {
  local block; block=$(extract_named_block "$WF" "tier-2 sweep")
  printf '%s' '{"results":[{"vulns":[{"id":"bad-detail"}]}]}' > "$BATS_TEST_TMPDIR/batch.json"
  mkdir -p "$BATS_TEST_TMPDIR/d2"
  printf 'not json' > "$BATS_TEST_TMPDIR/d2/bad-detail.json"
  run bash -c "
    set -uo pipefail
    npm_bump_extract() { bash scripts/npm-bump-extract.sh \"\$@\"; }
    DIFF=\$(cat '$NPMFX/real-lockfile-only.diff')
    OSV_BATCH_FIXTURE='$BATS_TEST_TMPDIR/batch.json'
    OSV_DETAIL_FIXTURE_DIR='$BATS_TEST_TMPDIR/d2'
    OSV_TOTAL=0; SCAN_ERROR_COUNT=0; HAS_ERROR=false; TIER2_SECTION=''
    $block
    printf 'ERRC=%s OSV_TOTAL=%s\n' \"\$SCAN_ERROR_COUNT\" \"\$OSV_TOTAL\"
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRC=1"* ]] || return 1
  [[ "$output" == *"OSV_TOTAL=0"* ]] || return 1
}

@test "tier-2 sweep is skipped when the diff introduces no lockfile entries" {
  # A manifest-only bump has no newly introduced lockfile versions, so the
  # sweep must not run, must not error, and must render no section.
  run_sweep '{"results":[{}]}' "$NPMFX/manifest-without-lock.diff"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIER2_COUNT=0"* ]] || return 1
  [[ "$output" == *"ERRC=0"* ]] || return 1
  [[ "$output" == *"SECTION<<>>"* ]] || return 1
}

# ---------------------------------------------------------------------------
# Task 20 — age counts split age-only failures (empty $7 reason) from
# supply-risk failures (yanked/deprecated, non-empty $7), so reporting can
# stop describing every `fail` row as "younger than Nd".
# ---------------------------------------------------------------------------

# Emit one TSV row per argument. Tabs written as \t; %b expands them.
age_tsv() {
  local row
  for row in "$@"; do printf '%b\n' "$row"; done
}

@test "age counts split age-only failures from supply-risk failures" {
  AGE_TSV=$(age_tsv 'a\t1.0.0\tnpm\t2026-04-01T00:00:00Z\t2\tfail\t' \
                    'b\t2.0.0\tnpm\t2019-01-01T00:00:00Z\t2500\tfail\tdeprecated' \
                    'c\t3.0.0\tpypi\t2019-01-01T00:00:00Z\t2500\tfail\tyanked' \
                    'd\t4.0.0\tnpm\t2020-01-01T00:00:00Z\t2000\tpass\t')
  eval "$(extract_named_block "$WF" 'age counts')"
  [ "$AGE_VIOLATION_COUNT" -eq 3 ]
  [ "$AGE_ONLY_COUNT" -eq 1 ]
  [ "$SUPPLY_RISK_COUNT" -eq 2 ]
}

@test "a deprecation-only failure yields no age-only violations" {
  AGE_TSV=$(age_tsv 'b\t2.0.0\tnpm\t2019-01-01T00:00:00Z\t2500\tfail\tdeprecated')
  eval "$(extract_named_block "$WF" 'age counts')"
  [ "$AGE_VIOLATION_COUNT" -eq 1 ]
  [ "$AGE_ONLY_COUNT" -eq 0 ]
  [ "$SUPPLY_RISK_COUNT" -eq 1 ]
}

@test "no earliest-age-compliant footer when every failure is a deprecation" {
  AGE_TSV=$(age_tsv 'b\t2.0.0\tnpm\t2019-01-01T00:00:00Z\t2500\tfail\tdeprecated')
  MINIMUM_RELEASE_AGE_DAYS=5
  eval "$(extract_named_block "$WF" 'age counts')"
  eval "$(extract_named_block "$WF" 'release age section')"
  [ -z "$AGE_FOOTER" ]
  [[ "$RELEASE_AGE_SECTION" == *'❌ blocked (deprecated)'* ]] || return 1
  [[ "$RELEASE_AGE_SECTION" != *'age-compliant date'* ]] || return 1
}

@test "the footer still appears when a genuine age failure is present" {
  AGE_TSV=$(age_tsv 'a\t1.0.0\tnpm\t2026-04-01T00:00:00Z\t2\tfail\t' \
                    'b\t2.0.0\tnpm\t2019-01-01T00:00:00Z\t2500\tfail\tdeprecated')
  MINIMUM_RELEASE_AGE_DAYS=5
  eval "$(extract_named_block "$WF" 'age counts')"
  eval "$(extract_named_block "$WF" 'release age section')"
  [[ "$AGE_FOOTER" == *'age-compliant date'* ]] || return 1
  # This 2026-04-06 date is also what MAX_FAIL_EPOCH's plain max() would produce
  # with no exclusion at all, since the deprecation row (2019) is already the
  # earlier date here. It does NOT discriminate the -z "$_reason" exclusion —
  # see "the unblock date is never pulled from a later-dated deprecation row"
  # below for the test that actually proves the exclusion is load-bearing.
  [[ "$AGE_FOOTER" == *'2026-04-06'* ]] || return 1
  [[ "$AGE_FOOTER" == *'1 package(s) below minimum'* ]] || return 1
}

@test "the unblock date is never pulled from a later-dated deprecation row" {
  # Discriminating arrangement: the deprecated row is dated AFTER the age-only
  # row. A max()-only computation (no -z "$_reason" exclusion) would seed
  # MAX_FAIL_EPOCH from the 2026-09-01 deprecation row and report 2026-09-06;
  # the exclusion must keep it seeded from the 2026-04-01 age-only row instead,
  # reporting 2026-04-06. Proven to discriminate in the report's revert/restore
  # round-trip (Task 20 review fix).
  AGE_TSV=$(age_tsv 'a\t1.0.0\tnpm\t2026-04-01T00:00:00Z\t2\tfail\t' \
                    'b\t2.0.0\tnpm\t2026-09-01T00:00:00Z\t2\tfail\tdeprecated')
  MINIMUM_RELEASE_AGE_DAYS=5
  eval "$(extract_named_block "$WF" 'age counts')"
  eval "$(extract_named_block "$WF" 'release age section')"
  [[ "$AGE_FOOTER" == *'2026-04-06'* ]] || return 1
  [[ "$AGE_FOOTER" != *'2026-09-06'* ]] || return 1
}
