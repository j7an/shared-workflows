coverage_fixture_init() {
  COVERAGE_REAL_DIFF_COVER_PATH=$DIFF_COVER_PATH
  COVERAGE_FIXTURE_ROOT="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$COVERAGE_FIXTURE_ROOT/src" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" init -q || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" config user.email coverage@example.invalid || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" config user.name "Coverage Fixture" || return 1
  printf 'def base():\n    return 1\n' >"$COVERAGE_FIXTURE_ROOT/src/app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm base || return 1
  COVERAGE_BASE_SHA=$(git -C "$COVERAGE_FIXTURE_ROOT" rev-parse HEAD) || return 1
  COVERAGE_DEFAULT_BRANCH=$(git -C "$COVERAGE_FIXTURE_ROOT" branch --show-current) || return 1
  COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/output"
  GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/step-summary.md"
  DIFF_COVER_PATH="$BATS_TEST_TMPDIR/diff-cover"
  coverage_fixture_write_fake_evaluator || return 1
}

coverage_fixture_commit_change() {
  printf 'def changed():\n    return 2\n' >>"$COVERAGE_FIXTURE_ROOT/src/app.py" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add src/app.py || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm change || return 1
}

coverage_fixture_commit_file() {
  local repository_path=$1 content=$2
  mkdir -p "$(dirname "$COVERAGE_FIXTURE_ROOT/$repository_path")" || return 1
  printf '%s' "$content" >"$COVERAGE_FIXTURE_ROOT/$repository_path" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" add -- "$repository_path" || return 1
  git -C "$COVERAGE_FIXTURE_ROOT" -c commit.gpgsign=false commit -qm "change $repository_path" || return 1
}

coverage_fixture_write_fake_evaluator() {
  cat >"$DIFF_COVER_PATH" <<'SH' || return 1
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'diff-cover 10.2.0'
  if [ "${COVERAGE_FAKE_EVALUATOR_ACTION:-}" = launch-failure ]; then
    mv -- "$0" "$0.gone" || exit 1
  fi
  exit 0
fi
printf '%s\n' "$@" >"${COVERAGE_FAKE_ARGV_LOG:?}"
formats=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--format" ]; then
    formats=$2
    break
  fi
  shift
done
json_path=${formats#json:}
json_path=${json_path%%,markdown:*}
markdown_path=${formats#*,markdown:}
case ${COVERAGE_FAKE_EVALUATOR_ACTION:-valid} in
  missing-json)
    ;;
  malformed-json)
    printf '%s' '{bad json' >"$json_path"
    ;;
  incomplete)
    printf '%s' '{"report_name":"Diff Coverage"}' >"$json_path"
    ;;
  inconsistent-totals)
    printf '%s' '{"report_name":"Diff Coverage","diff_name":"fixture","src_stats":{},"total_num_lines":1,"total_num_violations":2,"total_percent_covered":0,"num_changed_lines":1}' >"$json_path"
    ;;
  inconsistent-percent)
    printf '%s' '{"report_name":"Diff Coverage","diff_name":"fixture","src_stats":{"src/app.py":{"percent_covered":99,"violation_lines":[3],"covered_lines":[],"violations":[[3,null]]}},"total_num_lines":1,"total_num_violations":1,"total_percent_covered":99,"num_changed_lines":1}' >"$json_path"
    ;;
  mismatch|below)
    printf '%s' '{"report_name":"Diff Coverage","diff_name":"fixture","src_stats":{"src/app.py":{"percent_covered":0,"violation_lines":[3],"covered_lines":[],"violations":[[3,null]]}},"total_num_lines":1,"total_num_violations":1,"total_percent_covered":0,"num_changed_lines":1}' >"$json_path"
    ;;
  *)
    printf '%s' '{"report_name":"Diff Coverage","diff_name":"fixture","src_stats":{},"total_num_lines":0,"total_num_violations":0,"total_percent_covered":100,"num_changed_lines":0}' >"$json_path"
    ;;
esac
[ "${COVERAGE_FAKE_EVALUATOR_ACTION:-}" = incomplete ] || printf '%s\n' '# Diff Coverage' >"$markdown_path"
printf 'fake stdout <unsafe>\n'
printf 'fake stderr & unsafe\n' >&2
if [ "${COVERAGE_FAKE_EVALUATOR_ACTION:-}" = commit ]; then
  printf '%s\n' 'tool changed HEAD' > tool-created.txt
  git add tool-created.txt
  git -c commit.gpgsign=false commit -qm tool-created-head
fi
case ${COVERAGE_FAKE_EVALUATOR_ACTION:-} in
  incomplete|exit-one|below) exit 1 ;;
  exit-two) exit 2 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$DIFF_COVER_PATH" || return 1
}

coverage_write_cobertura() {
  local report=$1 repository_path=$2 line=$3 hits=$4
  mkdir -p "$(dirname "$report")" || return 1
  printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source></source></sources><packages><package name=""><classes>' "<class name=\"fixture\" filename=\"$repository_path\"><lines><line number=\"$line\" hits=\"$hits\"/></lines></class>" '</classes></package></packages></coverage>' >"$report" || return 1
}

coverage_write_lcov() {
  local report=$1 repository_path=$2 line=$3 hits=$4
  mkdir -p "$(dirname "$report")" || return 1
  printf 'SF:%s\nDA:%s,%s\nend_of_record\n' "$repository_path" "$line" "$hits" >"$report" || return 1
}

coverage_write_cobertura_lines() {
  local report=$1 repository_path=$2
  shift 2
  mkdir -p "$(dirname "$report")" || return 1
  {
    printf '%s\n' '<?xml version="1.0"?>' '<coverage><sources><source></source></sources><packages><package name=""><classes>' "<class name=\"fixture\" filename=\"$repository_path\"><lines>"
    while [ "$#" -gt 0 ]; do
      printf '<line number="%s" hits="%s"/>\n' "$1" "$2"
      shift 2
    done
    printf '%s\n' '</lines></class>' '</classes></package></packages></coverage>'
  } >"$report" || return 1
}

coverage_write_lcov_lines() {
  local report=$1 repository_path=$2
  shift 2
  mkdir -p "$(dirname "$report")" || return 1
  {
    printf 'SF:%s\n' "$repository_path"
    while [ "$#" -gt 0 ]; do
      printf 'DA:%s,%s\n' "$1" "$2"
      shift 2
    done
    printf 'end_of_record\n'
  } >"$report" || return 1
}

coverage_use_real_evaluator() {
  DIFF_COVER_PATH=$COVERAGE_REAL_DIFF_COVER_PATH
}

coverage_run_real_pair() {
  local repository_path=$1 expected_status=$2 expected_outcome=$3 expected_lines=$4 expected_violations=$5 expected_percent=$6 expected_changed=$7
  shift 7
  local format report
  coverage_use_real_evaluator || return 1
  for format in xml lcov; do
    report="$BATS_TEST_TMPDIR/report.$format"
    if [ "$format" = xml ]; then
      coverage_write_cobertura_lines "$report" "$repository_path" "$@" || return 1
    else
      coverage_write_lcov_lines "$report" "$repository_path" "$@" || return 1
    fi
    COVERAGE_OUTPUT_DIRECTORY="$BATS_TEST_TMPDIR/output-$format"
    run_coverage_evaluator "$report"
    assert_evaluation "$expected_status" "$expected_outcome" "$expected_lines" "$expected_violations" "$expected_percent" "$expected_changed" || return 1
  done
}

run_coverage_evaluator() {
  run env \
    COVERAGE_REPORT_PATH="$1" \
    COVERAGE_DIFF_COVER_PATH="$DIFF_COVER_PATH" \
    COVERAGE_BASE_SHA="$COVERAGE_BASE_SHA" \
    COVERAGE_MINIMUM="${COVERAGE_MINIMUM:-90}" \
    COVERAGE_SOURCE_PATHS="${COVERAGE_SOURCE_PATHS:-src/}" \
    COVERAGE_EXCLUDE_PATHS="${COVERAGE_EXCLUDE_PATHS:-}" \
    COVERAGE_WORKING_DIRECTORY="${COVERAGE_WORKING_DIRECTORY:-$COVERAGE_FIXTURE_ROOT}" \
    COVERAGE_OUTPUT_DIRECTORY="$COVERAGE_OUTPUT_DIRECTORY" \
    COVERAGE_RUNNER_OS="${COVERAGE_RUNNER_OS:-Linux}" \
    COVERAGE_FAKE_EVALUATOR_ACTION="${COVERAGE_FAKE_EVALUATOR_ACTION:-}" \
    COVERAGE_FAKE_ARGV_LOG="$BATS_TEST_TMPDIR/fake-argv.log" \
    GITHUB_WORKSPACE="$BATS_TEST_TMPDIR" \
    GITHUB_STEP_SUMMARY="$GITHUB_STEP_SUMMARY" \
    python3 "$BATS_TEST_DIRNAME/../actions/coverage/evaluate.py" || return 1
}

run_coverage_evaluator_without() {
  local missing=$1
  local pair name
  local args=(env)
  for pair in \
    "COVERAGE_REPORT_PATH=$BATS_TEST_TMPDIR/report.xml" \
    "COVERAGE_DIFF_COVER_PATH=$DIFF_COVER_PATH" \
    "COVERAGE_BASE_SHA=$COVERAGE_BASE_SHA" \
    'COVERAGE_MINIMUM=90' \
    'COVERAGE_SOURCE_PATHS=src/' \
    'COVERAGE_EXCLUDE_PATHS=' \
    "COVERAGE_WORKING_DIRECTORY=$COVERAGE_FIXTURE_ROOT" \
    "COVERAGE_OUTPUT_DIRECTORY=$COVERAGE_OUTPUT_DIRECTORY" \
    'COVERAGE_RUNNER_OS=Linux' \
    "GITHUB_WORKSPACE=$BATS_TEST_TMPDIR" \
    "GITHUB_STEP_SUMMARY=$GITHUB_STEP_SUMMARY"; do
    name=${pair%%=*}
    [ "$name" = "$missing" ] || args+=("$pair")
  done
  run "${args[@]}" python3 "$BATS_TEST_DIRNAME/../actions/coverage/evaluate.py" || return 1
}
