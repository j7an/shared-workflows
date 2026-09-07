#!/usr/bin/env bats

load 'helpers/coverage-action-fixture'

setup() {
  if [ -z "${DIFF_COVER_PATH:-}" ] || [ ! -x "$DIFF_COVER_PATH" ]; then
    printf 'DIFF_COVER_PATH must name an executable diff-cover 10.x test tool\n' >&2
    return 1
  fi
  coverage_fixture_init || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1 || return 1
  return 0
}

assert_evaluation() {
  local expected_status=$1 expected_outcome=$2 expected_lines=$3 expected_violations=$4 expected_percent=$5 expected_changed=$6
  if [ "$status" -ne "$expected_status" ]; then
    printf 'expected status %s, got %s; output: %s\n' "$expected_status" "$status" "$output" >&2
    [ ! -f "$COVERAGE_OUTPUT_DIRECTORY/diff-cover.json" ] || cat "$COVERAGE_OUTPUT_DIRECTORY/diff-cover.json" >&2
    [ ! -f "$COVERAGE_OUTPUT_DIRECTORY/diagnostics.txt" ] || cat "$COVERAGE_OUTPUT_DIRECTORY/diagnostics.txt" >&2
    return 1
  fi
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" "$expected_outcome" "$expected_lines" "$expected_violations" "$expected_percent" "$expected_changed" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
evaluation = metadata["evaluation"]
assert evaluation["outcome"] == sys.argv[2]
assert evaluation["total_num_lines"] == int(sys.argv[3])
assert evaluation["total_num_violations"] == int(sys.argv[4])
expected = None if sys.argv[5] == "none" else int(sys.argv[5])
assert evaluation["total_percent_covered"] == expected
assert evaluation["num_changed_lines"] == int(sys.argv[6])
PY
  [ "$?" -eq 0 ] || return 1
  [ "$(cat "$COVERAGE_OUTPUT_DIRECTORY/status")" = "$expected_status" ] || return 1
}

assert_diagnostic_bundle() {
  local report=$1
  [ -f "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" ] || return 1
  [ -f "$COVERAGE_OUTPUT_DIRECTORY/diff-cover.json" ] || return 1
  [ -f "$COVERAGE_OUTPUT_DIRECTORY/diff-cover.md" ] || return 1
  [ -f "$COVERAGE_OUTPUT_DIRECTORY/stdout.txt" ] || return 1
  [ -f "$COVERAGE_OUTPUT_DIRECTORY/stderr.txt" ] || return 1
  [ -f "$COVERAGE_OUTPUT_DIRECTORY/summary.md" ] || return 1
  cmp "$report" "$COVERAGE_OUTPUT_DIRECTORY/coverage-report.${report##*.}" || return 1
  cmp "$COVERAGE_OUTPUT_DIRECTORY/summary.md" "$GITHUB_STEP_SUMMARY" || return 1
}

assert_input_error() {
  [ "$status" -eq 2 ] || return 1
  grep -Fq -- "$1" "$COVERAGE_OUTPUT_DIRECTORY/diagnostics.txt" || return 1
  [ "$(cat "$COVERAGE_OUTPUT_DIRECTORY/status")" = 2 ] || return 1
  [ "$(wc -c < "$COVERAGE_OUTPUT_DIRECTORY/metadata.json")" -lt 4096 ] || return 1
  return 0
}

run_coverage_finalizer() {
  local evaluation_outcome=$1 upload_outcome=$2 status_content=${3-}
  mkdir -p "$COVERAGE_OUTPUT_DIRECTORY" || return 1
  printf '%s' 'Original bounded coverage diagnosis.' >"$GITHUB_STEP_SUMMARY" || return 1
  if [ -n "$status_content" ]; then
    printf '%s' "$status_content" >"$COVERAGE_OUTPUT_DIRECTORY/status" || return 1
  fi
  run env \
    COVERAGE_OUTPUT_DIRECTORY="$COVERAGE_OUTPUT_DIRECTORY" \
    COVERAGE_EVALUATE_OUTCOME="$evaluation_outcome" \
    COVERAGE_UPLOAD_OUTCOME="$upload_outcome" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    python3 "$BATS_TEST_DIRNAME/../actions/coverage/finalize.py"
}

@test "finalizer returns each valid stored evaluation status" {
  local expected outcome
  for expected in 0 1 2; do
    outcome=failure
    [ "$expected" -eq 0 ] && outcome=success
    COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/finalize-$expected"
    run_coverage_finalizer "$outcome" success "$expected"$'\n'
    [ "$status" -eq "$expected" ] || return 1
    [ "$(cat "$GITHUB_STEP_SUMMARY")" = 'Original bounded coverage diagnosis.' ] || return 1
  done
}

@test "finalizer rejects absent and invalid stored statuses" {
  run_coverage_finalizer failure success ''
  [ "$status" -eq 2 ] || return 1
  grep -Fq 'Coverage reporting error' "$GITHUB_STEP_SUMMARY" || return 1
  grep -Fq 'Original bounded coverage diagnosis.' "$GITHUB_STEP_SUMMARY" || return 1

  COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/finalize-invalid"
  run_coverage_finalizer failure success $'10\n'
  [ "$status" -eq 2 ] || return 1
  grep -Fq 'Coverage reporting error' "$GITHUB_STEP_SUMMARY" || return 1
}

@test "finalizer reports an evaluation launch failure without discarding diagnostics" {
  run_coverage_finalizer failure success ''
  [ "$status" -eq 2 ] || return 1
  grep -Fq 'Coverage reporting error' "$GITHUB_STEP_SUMMARY" || return 1
  grep -Fq 'Original bounded coverage diagnosis.' "$GITHUB_STEP_SUMMARY" || return 1
}

@test "finalizer fails reporting after every valid evaluation status and keeps diagnosis" {
  local expected
  for expected in 0 1 2; do
    COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/finalize-upload-$expected"
    run_coverage_finalizer failure failure "$expected"$'\n'
    [ "$status" -eq 2 ] || return 1
    grep -Fq 'Coverage reporting error' "$GITHUB_STEP_SUMMARY" || return 1
    grep -Fq 'Original bounded coverage diagnosis.' "$GITHUB_STEP_SUMMARY" || return 1
  done
}

@test "finalizer preserves a threshold failure after successful upload" {
  run_coverage_finalizer failure success $'1\n'
  [ "$status" -eq 1 ] || return 1
  [ "$(cat "$GITHUB_STEP_SUMMARY")" = 'Original bounded coverage diagnosis.' ] || return 1
}

@test "finalizer rejects mismatched or incomplete evaluation outcomes" {
  local evaluation
  for evaluation in success skipped cancelled '' ; do
    COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/finalize-outcome-${evaluation:-missing}"
    run_coverage_finalizer "$evaluation" success $'1\n'
    [ "$status" -eq 2 ] || return 1
    grep -Fq 'Coverage reporting error' "$GITHUB_STEP_SUMMARY" || return 1
    grep -Fq 'Original bounded coverage diagnosis.' "$GITHUB_STEP_SUMMARY" || return 1
  done

  COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/finalize-failure-zero"
  run_coverage_finalizer failure success $'0\n'
  [ "$status" -eq 2 ] || return 1
  grep -Fq 'Coverage reporting error' "$GITHUB_STEP_SUMMARY" || return 1
  grep -Fq 'Original bounded coverage diagnosis.' "$GITHUB_STEP_SUMMARY" || return 1
}

@test "rejects every absent required action input" {
  for variable in COVERAGE_REPORT_PATH COVERAGE_DIFF_COVER_PATH COVERAGE_BASE_SHA COVERAGE_MINIMUM COVERAGE_SOURCE_PATHS; do
    run_coverage_evaluator_without "$variable"
    assert_input_error "required-input" || return 1
  done
}

@test "rejects non-Linux runners" {
  COVERAGE_RUNNER_OS=macOS
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "unsupported-runner" || return 1
}

@test "rejects non-finite and out-of-range thresholds" {
  for value in nan -0.1 100.1; do
    COVERAGE_MINIMUM=$value
    run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
    assert_input_error "invalid-minimum" || return 1
  done
}

@test "rejects a working directory that is not a checkout root" {
  COVERAGE_FIXTURE_ROOT="$COVERAGE_FIXTURE_ROOT/src"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-working-directory" || return 1
}

@test "rejects a working directory outside GITHUB_WORKSPACE" {
  COVERAGE_FIXTURE_ROOT=/private/tmp
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-working-directory" || return 1
}

@test "rejects invalid base SHA and unusable diff-cover path" {
  COVERAGE_BASE_SHA=abcd
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-base-sha" || return 1
  COVERAGE_BASE_SHA=0000000000000000000000000000000000000000
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-base-sha" || return 1
  COVERAGE_BASE_SHA=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD) || return 1
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/missing-tool"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-diff-cover" || return 1
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/not-executable"
  printf '#!/bin/sh\n' >"$DIFF_COVER_PATH" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-diff-cover" || return 1
  chmod +x "$DIFF_COVER_PATH" || return 1
  printf '#!/bin/sh\nprintf "diff-cover 9.9.9\\n"\n' >"$DIFF_COVER_PATH" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "unsupported-diff-cover" || return 1
}

@test "rejects empty unmatched and negative source pathspecs" {
  COVERAGE_SOURCE_PATHS=$'\n'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-source-pathspecs" || return 1
  COVERAGE_SOURCE_PATHS='missing/'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "empty-production-scope" || return 1
  COVERAGE_SOURCE_PATHS=':(top,exclude)src/app.py'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-source-pathspecs" || return 1
}

@test "rejects negative exclusion pathspecs" {
  COVERAGE_EXCLUDE_PATHS=':(top,exclude)src/app.py'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-exclude-pathspecs" || return 1
}

@test "preserves the exclusion category for a Git-rejected pathspec" {
  COVERAGE_EXCLUDE_PATHS=':(glob'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-exclude-pathspecs" || return 1
}

@test "rejects unreadable, empty, unsupported, and malformed reports" {
  run_coverage_evaluator "$BATS_TEST_TMPDIR/missing.xml"
  assert_input_error "invalid-report" || return 1
  : >"$BATS_TEST_TMPDIR/empty.xml" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/empty.xml"
  assert_input_error "invalid-report" || return 1
  printf 'x' >"$BATS_TEST_TMPDIR/report.txt" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.txt"
  assert_input_error "unsupported-report" || return 1
  printf '<coverage><class filename="src/app.py"></coverage>' >"$BATS_TEST_TMPDIR/bad.xml" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad.xml"
  assert_input_error "malformed-cobertura" || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/negative-hits.xml" src/app.py 1 -1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/negative-hits.xml"
  assert_input_error "malformed-cobertura" || return 1
  printf 'SF:src/app.py\nDA:1,1\n' >"$BATS_TEST_TMPDIR/bad.info" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad.info"
  assert_input_error "malformed-lcov" || return 1
  printf 'SF:src/app.py\nBRDA:1,0,0,x\nend_of_record\n' >"$BATS_TEST_TMPDIR/bad-branch.info" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad-branch.info"
  assert_input_error "malformed-lcov" || return 1
}

@test "rejects control characters in path-bearing action inputs and Cobertura roots" {
  COVERAGE_REPORT_PATH=$'bad\r.xml'
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-report" || return 1
  COVERAGE_REPORT_PATH="$BATS_TEST_TMPDIR/report.xml"
  COVERAGE_WORKING_DIRECTORY=$'repo\r'
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-working-directory" || return 1
  COVERAGE_WORKING_DIRECTORY="$COVERAGE_FIXTURE_ROOT"
  COVERAGE_SOURCE_PATHS=$'src/\r'
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-source-pathspecs" || return 1
  COVERAGE_SOURCE_PATHS=src/
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source>src&#13;</source></sources><packages><package name=""><classes>' '<class name="fixture" filename="app.py"><lines><line number="1" hits="1"/></lines></class>' '</classes></package></packages></coverage>' >"$COVERAGE_REPORT_PATH" || return 1
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-report-path" || return 1
}

@test "rejects foreign and ambiguous report identities" {
  coverage_write_lcov "$BATS_TEST_TMPDIR/foreign.info" /tmp/app.py 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/foreign.info"
  assert_input_error "invalid-report-path" || return 1
  coverage_write_lcov "$BATS_TEST_TMPDIR/escape.info" ../outside.py 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/escape.info"
  assert_input_error "invalid-report-path" || return 1
  mkdir -p "$COVERAGE_FIXTURE_ROOT/src/a" "$COVERAGE_FIXTURE_ROOT/src/b" || return 1
  printf 'def first():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/a/app.py" || return 1
  printf 'def second():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/b/app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/a/app.py src/b/app.py || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm ambiguous-files || return 1
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source>src/a</source><source>src/b</source></sources><packages><package name=""><classes>' '<class name="fixture" filename="app.py"><lines><line number="1" hits="1"/></lines></class>' '</classes></package></packages></coverage>' >"$BATS_TEST_TMPDIR/ambiguous.xml" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/ambiguous.xml"
  assert_input_error "ambiguous-report-path" || return 1
}

@test "rejects a regular report when read access is unavailable" {
  run python3 - "$BATS_TEST_DIRNAME/../actions/coverage/evaluate.py" "$BATS_TEST_TMPDIR/report.xml" "$DIFF_COVER_PATH" "$COVERAGE_BASE_SHA" "$COVERAGE_FIXTURE_ROOT" "$COVERAGE_OUTPUT_DIRECTORY" "$BATS_TEST_TMPDIR" "$GITHUB_STEP_SUMMARY" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("evaluate", sys.argv[1])
evaluate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = evaluate
spec.loader.exec_module(evaluate)
report = os.path.realpath(sys.argv[2])
access = evaluate.os.access
evaluate.os.access = lambda path, mode: False if os.path.realpath(path) == report and mode == os.R_OK else access(path, mode)
env = {
    "COVERAGE_REPORT_PATH": sys.argv[2],
    "COVERAGE_DIFF_COVER_PATH": sys.argv[3],
    "COVERAGE_BASE_SHA": sys.argv[4],
    "COVERAGE_MINIMUM": "90",
    "COVERAGE_SOURCE_PATHS": "src/",
    "COVERAGE_EXCLUDE_PATHS": "",
    "COVERAGE_WORKING_DIRECTORY": sys.argv[5],
    "COVERAGE_OUTPUT_DIRECTORY": sys.argv[6],
    "COVERAGE_RUNNER_OS": "Linux",
    "GITHUB_WORKSPACE": sys.argv[7],
    "GITHUB_STEP_SUMMARY": sys.argv[8],
}
try:
    evaluate.main(env)
except SystemExit as error:
    sys.exit(error.code)
PY
  assert_input_error "invalid-report" || return 1
}

@test "rejects an output path containing NUL without a traceback" {
  run python3 - "$BATS_TEST_DIRNAME/../actions/coverage/evaluate.py" <<'PY'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("evaluate", sys.argv[1])
evaluate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = evaluate
spec.loader.exec_module(evaluate)
env = dict(os.environ, COVERAGE_OUTPUT_DIRECTORY="bad\0output")
try:
    evaluate.main(env)
except SystemExit as error:
    sys.exit(error.code)
PY
  [ "$status" -eq 2 ] || return 1
  [[ "$output" == *"invalid-output-directory"* ]] || return 1
  [[ "$output" != *"Traceback"* ]] || return 1
}

@test "writes valid bounded metadata for many long pathspec values" {
  run python3 - "$BATS_TEST_DIRNAME/../actions/coverage/evaluate.py" "$COVERAGE_OUTPUT_DIRECTORY" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("evaluate", sys.argv[1])
evaluate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = evaluate
spec.loader.exec_module(evaluate)
pathspecs = ["x" * 512 for _ in range(32)]
evaluate.write_outputs(evaluate.Path(sys.argv[2]), 0, "validated", {"inputs": {"source_pathspecs": pathspecs}})
payload = (evaluate.Path(sys.argv[2]) / "metadata.json").read_text(encoding="utf-8")
metadata = json.loads(payload)
stored_status = (evaluate.Path(sys.argv[2]) / "status").read_text(encoding="utf-8").strip()
sys.exit(0 if len(payload.encode("utf-8")) < 4096 and str(metadata["status"]) == stored_status else 1)
PY
  [ "$status" -eq 0 ] || return 1
}

@test "inventories Nexus-style relative Cobertura records" {
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  grep -Fq 'src/app.py' "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" || return 1
}

@test "inventories relative and checkout-absolute LCOV records" {
  coverage_write_lcov "$BATS_TEST_TMPDIR/relative.info" src/app.py 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/relative.info"
  [ "$status" -eq 0 ] || return 1
  coverage_write_lcov "$BATS_TEST_TMPDIR/absolute.info" "$COVERAGE_FIXTURE_ROOT/src/app.py" 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/absolute.info"
  [ "$status" -eq 0 ] || return 1
}

@test "comparison freezes a linear committed HEAD and its scoped patch" {
  coverage_fixture_commit_change || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1 || return 1
  tested_sha=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD) || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" "$COVERAGE_BASE_SHA" "$tested_sha" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
comparison = metadata["comparison"]
assert comparison["base_sha"] == sys.argv[2]
assert comparison["merge_base_sha"] == sys.argv[2]
assert comparison["tested_sha"] == sys.argv[3]
assert metadata["changed_paths"] == ["src/app.py"]
PY
  [ "$?" -eq 0 ] || return 1
  grep -Fq '+def changed():' "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
}

@test "comparison uses the merge-base for diverged histories and merge checkouts" {
  common_sha=$COVERAGE_BASE_SHA
  git -C "$COVERAGE_FIXTURE_ROOT" checkout -qb feature || return 1
  coverage_fixture_commit_file src/feature.py $'def feature():\n    return 1\n' || return 1
  feature_sha=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD) || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" checkout -q "$COVERAGE_DEFAULT_BRANCH" || return 1
  coverage_fixture_commit_file src/main.py $'def main():\n    return 1\n' || return 1
  main_sha=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD) || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" checkout -q feature || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/feature.py 1 1 || return 1
  COVERAGE_BASE_SHA=$main_sha
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" "$main_sha" "$feature_sha" "$common_sha" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
assert metadata["comparison"]["base_sha"] == sys.argv[2]
assert metadata["comparison"]["tested_sha"] == sys.argv[3]
assert metadata["comparison"]["merge_base_sha"] == sys.argv[4]
assert metadata["changed_paths"] == ["src/feature.py"]
PY
  [ "$?" -eq 0 ] || return 1
  grep -Fq '+def feature():' "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" checkout -q "$COVERAGE_DEFAULT_BRANCH" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false merge --no-ff -qm fixture-merge "$feature_sha" || return 1
  merge_sha=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD) || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/feature.py 1 1 || return 1
  COVERAGE_BASE_SHA=$main_sha
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" "$main_sha" "$merge_sha" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
assert metadata["comparison"]["base_sha"] == sys.argv[2]
assert metadata["comparison"]["tested_sha"] == sys.argv[3]
assert metadata["comparison"]["merge_base_sha"] == sys.argv[2]
assert metadata["changed_paths"] == ["src/feature.py"]
PY
  [ "$?" -eq 0 ] || return 1
}

@test "scope applies Git glob selectors and exclusions before report requirements" {
  coverage_fixture_commit_file src/nested/keep.py $'def keep():\n    return 1\n' || return 1
  coverage_fixture_commit_file src/nested/skip.py $'def skip():\n    return 1\n' || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/nested/keep.py 1 1 || return 1
  COVERAGE_SOURCE_PATHS=':(glob)src/**/*.py'
  COVERAGE_EXCLUDE_PATHS='src/nested/skip.py'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
assert metadata["effective_paths"] == ["src/app.py", "src/nested/keep.py"]
assert metadata["changed_paths"] == ["src/nested/keep.py"]
PY
  [ "$?" -eq 0 ] || return 1
}

@test "scope requires changed present production files in the report" {
  coverage_fixture_commit_file src/missing.py $'def missing():\n    return 1\n' || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "missing-changed-report-path" || return 1
}

@test "scope ignores staged unstaged and untracked changes" {
  coverage_fixture_commit_change || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  cp "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" "$BATS_TEST_TMPDIR/clean.diff" || return 1
  cp "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" "$BATS_TEST_TMPDIR/clean.json" || return 1
  printf '# staged\n' >>"$COVERAGE_FIXTURE_ROOT/src/app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py || return 1
  printf '# staged new\n' >"$COVERAGE_FIXTURE_ROOT/src/staged.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/staged.py || return 1
  printf '# unstaged\n' >>"$COVERAGE_FIXTURE_ROOT/src/app.py" || return 1
  printf '# untracked\n' >"$COVERAGE_FIXTURE_ROOT/src/untracked.py" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  cmp "$BATS_TEST_TMPDIR/clean.diff" "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
  cmp "$BATS_TEST_TMPDIR/clean.json" "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" || return 1
}

@test "scope preserves modified rename headers and validates only the post-image" {
  git -C "$COVERAGE_FIXTURE_ROOT" mv src/app.py 'src/renamed app.py' || return 1
  printf '# renamed\n' >>"$COVERAGE_FIXTURE_ROOT/src/renamed app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add -- 'src/renamed app.py' || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm renamed || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" 'src/renamed app.py' 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  grep -Fq 'rename from src/app.py' "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
  grep -Fq 'rename to src/renamed app.py' "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
  grep -Fq '+# renamed' "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
  ! grep -Fq '+def base():' "$COVERAGE_OUTPUT_DIRECTORY/scoped.diff" || return 1
}

@test "scope handles additions deletions nested paths and names containing spaces" {
  coverage_fixture_commit_file 'src/nested/new file.py' $'def added():\n    return 1\n' || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" rm -q src/app.py || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm deleted || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" 'src/nested/new file.py' 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  grep -Fq 'src/nested/new file.py' "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" || return 1
  ! grep -Fq 'src/app.py' "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["changed_paths"] == ["src/nested/new file.py"]
PY
  [ "$?" -eq 0 ] || return 1
}

@test "comparison rejects unavailable merge-base history" {
  git -C "$COVERAGE_FIXTURE_ROOT" checkout --orphan unrelated >/dev/null 2>&1 || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit --allow-empty -qm unrelated || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1 || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-comparison" || return 1
}

@test "comparison rejects an evaluator that changes tested HEAD" {
  coverage_fixture_commit_change || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1 || return 1
  COVERAGE_FAKE_EVALUATOR_ACTION=commit
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "tested-head-changed" || return 1
}

@test "XML and LCOV pass above the threshold with matching arithmetic" {
  coverage_fixture_commit_change || return 1
  coverage_run_real_pair src/app.py 0 pass 2 0 100 2 3 1 4 1 || return 1
}

@test "XML and LCOV pass exactly at the threshold with matching arithmetic" {
  coverage_fixture_commit_change || return 1
  COVERAGE_MINIMUM=50
  coverage_run_real_pair src/app.py 0 pass 2 1 50 2 3 1 4 0 || return 1
}

@test "XML and LCOV fail below the threshold with matching arithmetic" {
  coverage_fixture_commit_change || return 1
  COVERAGE_MINIMUM=51
  coverage_run_real_pair src/app.py 1 below-threshold 2 1 50 2 3 1 4 0 || return 1
  grep -Fq 'Uncovered changed lines' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq '4' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
}

@test "XML and LCOV preserve fractional threshold integer semantics" {
  printf 'first = 1\nsecond = 2\nthird = 3\n' >>"$COVERAGE_FIXTURE_ROOT/src/app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm fractional || return 1
  COVERAGE_MINIMUM=66.5
  coverage_run_real_pair src/app.py 1 below-threshold 3 1 66 3 3 1 4 1 5 0 || return 1
}

@test "XML and LCOV classify documentation-only changes as not applicable" {
  coverage_fixture_commit_file docs/readme.md $'documentation\n' || return 1
  coverage_run_real_pair src/app.py 0 not-applicable 0 0 none 0 1 1 || return 1
  ! grep -Eq '[0-9]+%' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
}

@test "XML and LCOV classify nonexecutable source changes as not applicable" {
  printf '# comment only\n' >>"$COVERAGE_FIXTURE_ROOT/src/app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm comment || return 1
  coverage_run_real_pair src/app.py 0 not-applicable 0 0 none 1 1 1 || return 1
  ! grep -Eq '[0-9]+%' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
}

@test "XML and LCOV classify represented unloaded source as below threshold" {
  coverage_fixture_commit_file src/unloaded.py $'unloaded = 1\n' || return 1
  COVERAGE_MINIMUM=1
  coverage_run_real_pair src/unloaded.py 1 below-threshold 1 1 0 1 1 0 || return 1
}

@test "tool result invocation uses only the approved explicit arguments" {
  coverage_fixture_commit_change || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ] || return 1
  python3 - "$BATS_TEST_TMPDIR/fake-argv.log" "$COVERAGE_OUTPUT_DIRECTORY" "$COVERAGE_BASE_SHA" <<'PY'
import os
import sys
args = open(sys.argv[1], encoding="utf-8").read().splitlines()
output = os.path.realpath(sys.argv[2])
assert "--diff-file" in args
assert "--compare-branch" in args
assert args[args.index("--compare-branch") + 1] == sys.argv[3]
assert "--quiet" in args
assert args[args.index("--format") + 1] == f"json:{output}/diff-cover.json,markdown:{output}/diff-cover.md"
for forbidden in ("--config-file", "--total-percent-float", "--include", "--exclude", "--expand-coverage-report"):
    assert forbidden not in args
PY
  [ "$?" -eq 0 ] || return 1
}

@test "tool result classifies only a complete proved threshold miss" {
  coverage_fixture_commit_change || return 1
  COVERAGE_FAKE_EVALUATOR_ACTION=below
  COVERAGE_MINIMUM=1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_evaluation 1 below-threshold 1 1 0 1 || return 1
}

@test "tool result failures and inconsistent structured output fail closed" {
  local mode index=0
  coverage_fixture_commit_change || return 1
  for mode in launch-failure exit-one exit-two missing-json malformed-json incomplete inconsistent-totals inconsistent-percent mismatch nonfinite-source-percent duplicate-lines mismatched-violations inconsistent-source-percent; do
    index=$((index + 1))
    COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/output-failure-$index"
    COVERAGE_FAKE_EVALUATOR_ACTION=$mode
    run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
    assert_input_error evaluator-failed || return 1
    coverage_fixture_write_fake_evaluator || return 1
  done
  grep -Fq 'Evaluator failed or returned incomplete or inconsistent output.' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq 'Inspect diff-cover.json, diff-cover.md, stdout.txt, and stderr.txt' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
}

@test "tool result diagnostics escape display data and retain upstream artifacts" {
  coverage_fixture_commit_change || return 1
  local report="$BATS_TEST_TMPDIR/report <unsafe>&.xml"
  coverage_write_cobertura_lines "$report" src/app.py 3 1 4 0 || return 1
  COVERAGE_FAKE_EVALUATOR_ACTION=below
  COVERAGE_MINIMUM=1
  run_coverage_evaluator "$report"
  assert_evaluation 1 below-threshold 1 1 0 1 || return 1
  assert_diagnostic_bundle "$report" || return 1
  grep -Fq 'report &lt;unsafe&gt;&amp;.xml' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  ! grep -Fq 'report <unsafe>&.xml' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq 'fake stdout &lt;unsafe&gt;' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq 'fake stderr &amp; unsafe' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq "Base commit: <code>$COVERAGE_BASE_SHA</code>" "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq 'Minimum: <code>1</code>' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq '# Diff Coverage' "$COVERAGE_OUTPUT_DIRECTORY/diff-cover.md" || return 1
}

@test "tool result writes an immutable diagnostic snapshot before atomic status" {
  coverage_fixture_commit_change || return 1
  local report="$BATS_TEST_TMPDIR/report.xml"
  local old_inode new_inode
  mkdir -p "$COVERAGE_OUTPUT_DIRECTORY" || return 1
  printf '99\n' >"$COVERAGE_OUTPUT_DIRECTORY/status" || return 1
  old_inode=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$COVERAGE_OUTPUT_DIRECTORY/status") || return 1
  run_coverage_evaluator "$report"
  [ "$status" -eq 0 ] || return 1
  new_inode=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_ino)' "$COVERAGE_OUTPUT_DIRECTORY/status") || return 1
  [ "$old_inode" != "$new_inode" ] || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY" <<'PY'
import pathlib
import sys
output = pathlib.Path(sys.argv[1])
status_time = (output / "status").stat().st_mtime_ns
for name in ("coverage-report.xml", "diagnostics.txt", "diff-cover.json", "diff-cover.md",
             "metadata.json", "scoped.diff", "stderr.txt", "stdout.txt", "summary.md"):
    assert (output / name).stat().st_mtime_ns <= status_time, name
PY
  [ "$?" -eq 0 ] || return 1
  printf '<!-- changed after evaluation -->\n' >>"$report" || return 1
  ! cmp "$report" "$COVERAGE_OUTPUT_DIRECTORY/coverage-report.xml" >/dev/null 2>&1 || return 1
}

@test "summary publication failure retains the completed coverage diagnosis" {
  coverage_fixture_commit_change || return 1
  coverage_write_cobertura_lines "$BATS_TEST_TMPDIR/report.xml" src/app.py 3 1 4 0 || return 1
  COVERAGE_FAKE_EVALUATOR_ACTION=below
  COVERAGE_MINIMUM=1
  GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary-directory"
  mkdir "$GITHUB_STEP_SUMMARY" || return 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 2 ] || return 1
  [ "$(cat "$COVERAGE_OUTPUT_DIRECTORY/status")" = 2 ] || return 1
  grep -Fq 'below-threshold' "$COVERAGE_OUTPUT_DIRECTORY/diagnostics.txt" || return 1
  grep -Fq 'diagnostic-publication-failed' "$COVERAGE_OUTPUT_DIRECTORY/diagnostics.txt" || return 1
  grep -Fq 'Measured changed lines: 1' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq 'Uncovered changed lines: 1' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  grep -Fq 'Changed-line coverage: 0%' "$COVERAGE_OUTPUT_DIRECTORY/summary.md" || return 1
  python3 - "$COVERAGE_OUTPUT_DIRECTORY/metadata.json" <<'PY'
import json
import sys
metadata = json.load(open(sys.argv[1], encoding="utf-8"))
assert metadata["evaluation"]["outcome"] == "below-threshold"
assert metadata["evaluation"]["total_num_lines"] == 1
assert metadata["publication_error"] == "diagnostic-publication-failed"
assert metadata["status"] == 2
PY
  [ "$?" -eq 0 ] || return 1
}
