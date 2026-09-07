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
  assert_input_error "unsupported-runner"
}

@test "rejects non-finite and out-of-range thresholds" {
  for value in nan -0.1 100.1; do
    COVERAGE_MINIMUM=$value
    run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
    assert_input_error "invalid-minimum"
  done
}

@test "rejects a working directory that is not a checkout root" {
  COVERAGE_FIXTURE_ROOT="$COVERAGE_FIXTURE_ROOT/src"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-working-directory"
}

@test "rejects a working directory outside GITHUB_WORKSPACE" {
  COVERAGE_FIXTURE_ROOT=/private/tmp
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-working-directory"
}

@test "rejects invalid base SHA and unusable diff-cover path" {
  COVERAGE_BASE_SHA=abcd
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-base-sha"
  COVERAGE_BASE_SHA=0000000000000000000000000000000000000000
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-base-sha"
  COVERAGE_BASE_SHA=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD)
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/missing-tool"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-diff-cover"
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/not-executable"
  printf '#!/bin/sh\n' >"$DIFF_COVER_PATH"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-diff-cover"
  chmod +x "$DIFF_COVER_PATH"
  printf '#!/bin/sh\nprintf "diff-cover 9.9.9\\n"\n' >"$DIFF_COVER_PATH"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "unsupported-diff-cover"
}

@test "rejects empty and unmatched source pathspecs" {
  COVERAGE_SOURCE_PATHS=$'\n'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "invalid-source-pathspecs"
  COVERAGE_SOURCE_PATHS='missing/'
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.xml"
  assert_input_error "empty-production-scope"
}

@test "rejects unreadable, empty, unsupported, and malformed reports" {
  run_coverage_evaluator "$BATS_TEST_TMPDIR/missing.xml"
  assert_input_error "invalid-report"
  mkdir "$BATS_TEST_TMPDIR/unreadable.xml"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/unreadable.xml"
  assert_input_error "invalid-report"
  : >"$BATS_TEST_TMPDIR/empty.xml"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/empty.xml"
  assert_input_error "invalid-report"
  printf 'x' >"$BATS_TEST_TMPDIR/report.txt"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/report.txt"
  assert_input_error "unsupported-report"
  printf '<coverage><class filename="src/app.py"></coverage>' >"$BATS_TEST_TMPDIR/bad.xml"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad.xml"
  assert_input_error "malformed-cobertura"
  coverage_write_cobertura "$BATS_TEST_TMPDIR/negative-hits.xml" src/app.py 1 -1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/negative-hits.xml"
  assert_input_error "malformed-cobertura"
  printf 'SF:src/app.py\nDA:1,1\n' >"$BATS_TEST_TMPDIR/bad.info"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad.info"
  assert_input_error "malformed-lcov"
  printf 'SF:src/app.py\nBRDA:1,0,0,x\nend_of_record\n' >"$BATS_TEST_TMPDIR/bad-branch.info"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/bad-branch.info"
  assert_input_error "malformed-lcov"
}

@test "rejects control characters in path-bearing action inputs and Cobertura roots" {
  COVERAGE_REPORT_PATH=$'bad\r.xml'
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-report"
  COVERAGE_REPORT_PATH="$BATS_TEST_TMPDIR/report.xml"
  COVERAGE_WORKING_DIRECTORY=$'repo\r'
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-working-directory"
  COVERAGE_WORKING_DIRECTORY="$COVERAGE_FIXTURE_ROOT"
  COVERAGE_SOURCE_PATHS=$'src/\r'
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-source-pathspecs"
  COVERAGE_SOURCE_PATHS=src/
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source>src&#13;</source></sources><packages><package name=""><classes>' '<class name="fixture" filename="app.py"><lines><line number="1" hits="1"/></lines></class>' '</classes></package></packages></coverage>' >"$COVERAGE_REPORT_PATH"
  run_coverage_evaluator "$COVERAGE_REPORT_PATH"
  assert_input_error "invalid-report-path"
}

@test "rejects foreign and ambiguous report identities" {
  coverage_write_lcov "$BATS_TEST_TMPDIR/foreign.info" /tmp/app.py 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/foreign.info"
  assert_input_error "invalid-report-path"
  coverage_write_lcov "$BATS_TEST_TMPDIR/escape.info" ../outside.py 1 1
  run_coverage_evaluator "$BATS_TEST_TMPDIR/escape.info"
  assert_input_error "invalid-report-path"
  mkdir -p "$COVERAGE_FIXTURE_ROOT/src/a" "$COVERAGE_FIXTURE_ROOT/src/b"
  printf 'def first():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/a/app.py"
  printf 'def second():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/b/app.py"
  git -C "$COVERAGE_FIXTURE_ROOT" add src/a/app.py src/b/app.py
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm ambiguous-files
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source>src/a</source><source>src/b</source></sources><packages><package name=""><classes>' '<class name="fixture" filename="app.py"><lines><line number="1" hits="1"/></lines></class>' '</classes></package></packages></coverage>' >"$BATS_TEST_TMPDIR/ambiguous.xml"
  run_coverage_evaluator "$BATS_TEST_TMPDIR/ambiguous.xml"
  assert_input_error "ambiguous-report-path"
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
