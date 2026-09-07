#!/usr/bin/env bats

load 'helpers/coverage-action-fixture'

setup() {
  coverage_fixture_init
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1
}

assert_input_error() {
  [ "$status" -eq 2 ] || return 1
  grep -Fq -- "$1" "$COVERAGE_OUTPUT_DIRECTORY/diagnostics.txt" || return 1
  [ "$(cat "$COVERAGE_OUTPUT_DIRECTORY/status")" = 2 ] || return 1
  [ "$(wc -c < "$COVERAGE_OUTPUT_DIRECTORY/metadata.json")" -lt 4096 ] || return 1
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
  COVERAGE_BASE_SHA=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD)
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/missing-tool"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-diff-cover" || return 1
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/not-executable"
  printf '#!/bin/sh\n' >"$DIFF_COVER_PATH"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-diff-cover" || return 1
  chmod +x "$DIFF_COVER_PATH"
  printf '#!/bin/sh\nprintf "diff-cover 9.9.9\\n"\n' >"$DIFF_COVER_PATH"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "unsupported-diff-cover" || return 1
}

@test "rejects empty and unmatched source pathspecs" {
  COVERAGE_SOURCE_PATHS=$'\n'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-source-pathspecs" || return 1
  COVERAGE_SOURCE_PATHS='missing/'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "empty-production-scope" || return 1
}

@test "rejects unreadable, empty, unsupported, and malformed reports" {
  run_coverage_evaluator "$BATS_TEST_TMPDIR/missing.xml"
  assert_input_error "invalid-report" || return 1
  : >"$BATS_TEST_TMPDIR/empty.xml"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/empty.xml"
  assert_input_error "invalid-report" || return 1
  printf 'x' >"$BATS_TEST_TMPDIR/report.txt"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.txt"
  assert_input_error "unsupported-report" || return 1
  printf '<coverage><class filename="src/app.py"></coverage>' >"$BATS_TEST_TMPDIR/bad.xml"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad.xml"
  assert_input_error "malformed-cobertura" || return 1
  coverage_write_cobertura "$BATS_TEST_TMPDIR/negative-hits.xml" src/app.py 1 -1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/negative-hits.xml"
  assert_input_error "malformed-cobertura" || return 1
  printf 'SF:src/app.py\nDA:1,1\n' >"$BATS_TEST_TMPDIR/bad.info"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad.info"
  assert_input_error "malformed-lcov" || return 1
  printf 'SF:src/app.py\nBRDA:1,0,0,x\nend_of_record\n' >"$BATS_TEST_TMPDIR/bad-branch.info"
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
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source>src&#13;</source></sources><packages><package name=""><classes>' '<class name="fixture" filename="app.py"><lines><line number="1" hits="1"/></lines></class>' '</classes></package></packages></coverage>' >"$COVERAGE_REPORT_PATH"
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-report-path" || return 1
}

@test "rejects foreign and ambiguous report identities" {
  coverage_write_lcov "$BATS_TEST_TMPDIR/foreign.info" /tmp/app.py 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/foreign.info"
  assert_input_error "invalid-report-path" || return 1
  coverage_write_lcov "$BATS_TEST_TMPDIR/escape.info" ../outside.py 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/escape.info"
  assert_input_error "invalid-report-path" || return 1
  mkdir -p "$COVERAGE_FIXTURE_ROOT/src/a" "$COVERAGE_FIXTURE_ROOT/src/b"
  printf 'def first():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/a/app.py"
  printf 'def second():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/b/app.py"
  git -C "$COVERAGE_FIXTURE_ROOT" add src/a/app.py src/b/app.py
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm ambiguous-files
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source>src/a</source><source>src/b</source></sources><packages><package name=""><classes>' '<class name="fixture" filename="app.py"><lines><line number="1" hits="1"/></lines></class>' '</classes></package></packages></coverage>' >"$BATS_TEST_TMPDIR/ambiguous.xml"
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
json.loads(payload)
sys.exit(0 if len(payload.encode("utf-8")) < 4096 else 1)
PY
  [ "$status" -eq 0 ] || return 1
}

@test "inventories Nexus-style relative Cobertura records" {
  coverage_write_cobertura "$BATS_TEST_TMPDIR/report.xml" src/app.py 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  [ "$status" -eq 0 ]
  grep -Fq 'src/app.py' "$COVERAGE_OUTPUT_DIRECTORY/metadata.json"
}

@test "inventories relative and checkout-absolute LCOV records" {
  coverage_write_lcov "$BATS_TEST_TMPDIR/relative.info" src/app.py 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/relative.info"
  [ "$status" -eq 0 ]
  coverage_write_lcov "$BATS_TEST_TMPDIR/absolute.info" "$COVERAGE_FIXTURE_ROOT/src/app.py" 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/absolute.info"
  [ "$status" -eq 0 ]
}
