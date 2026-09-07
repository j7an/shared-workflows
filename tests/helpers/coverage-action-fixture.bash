coverage_fixture_init() {
  COVERAGE_FIXTURE_ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$COVERAGE_FIXTURE_ROOT/src"
  git -C "$COVERAGE_FIXTURE_ROOT" init -q
  git -C "$COVERAGE_FIXTURE_ROOT" config user.email coverage@example.invalid
  git -C "$COVERAGE_FIXTURE_ROOT" config user.name "Coverage Fixture"
  printf 'def base():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/app.py"
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm base
  COVERAGE_BASE_SHA=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD)
  COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/output"
  GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step-summary.md"
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/diff-cover"
  printf '#!/bin/sh\nprintf "diff-cover 10.2.0\\n"\n' >"$DIFF_COVER_PATH"
  chmod +x "$DIFF_COVER_PATH"
}

coverage_fixture_commit_change() {
  printf 'def changed():\n    return 2\n' >>"$COVERAGE_FIXTURE_ROOT/src/app.py"
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm change
}

coverage_write_cobertura() {
  local report=$1 repository_path=$2 line=$3 hits=$4
  mkdir -p "$(dirname "$report")"
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source></source></sources><packages><package name=""><classes>' "<class name=\"fixture\" filename=\"$repository_path\"><lines><line number=\"$line\" hits=\"$hits\"/></lines></class>" '</classes></package></packages></coverage>' >"$report"
}

coverage_write_lcov() {
  local report=$1 repository_path=$2 line=$3 hits=$4
  mkdir -p "$(dirname "$report")"
  printf 'SF:%s\nDA:%s,%s\nend_of_record\n' "$repository_path" "$line" "$hits" >"$report"
}

run_coverage_evaluator() {
  run env \
    COVERAGE_REPORT_PATH="$1" \
    COVERAGE_DIFF_COVER_PATH="$DIFF_COVER_PATH" \
    COVERAGE_BASE_SHA="$COVERAGE_BASE_SHA" \
    COVERAGE_MINIMUM="${COVERAGE_MINIMUM:-90}" \
    COVERAGE_SOURCE_PATHS="${COVERAGE_SOURCE_PATHS:-src/}" \
    COVERAGE_EXCLUDE_PATHS="${COVERAGE_EXCLUDE_PATHS:-}" \
    COVERAGE_WORKING_DIRECTORY="$COVERAGE_FIXTURE_ROOT" \
    COVERAGE_OUTPUT_DIRECTORY="$COVERAGE_OUTPUT_DIRECTORY" \
    COVERAGE_RUNNER_OS="${COVERAGE_RUNNER_OS:-Linux}" \
    GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    python3 "$BATS_TEST_DIRNAME/../actions/coverage/evaluate.py"
}
