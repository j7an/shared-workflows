#!/usr/bin/env bats

load 'helpers/action-pin-assertions'

ACTION='actions/coverage/action.yml'

step_block() {
  awk -v wanted="$1" '
    /^    - id: / {
      if (found) exit
      if ($3 == wanted) found = 1
    }
    found { print }
  ' "$ACTION"
}

input_block() {
  awk -v wanted="$1" '
    /^inputs:$/ { in_inputs = 1; next }
    in_inputs && /^runs:$/ { exit }
    in_inputs && /^  [^[:space:]][^:]*:$/ {
      if (found) exit
      name = $0
      sub(/^  /, "", name)
      sub(/:$/, "", name)
      if (name == wanted) found = 1
    }
    found { print }
  ' "$ACTION"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || return 1
}

assert_lacks() {
  [[ "$1" != *"$2"* ]] || return 1
}

@test "coverage action exposes only the seven documented inputs" {
  run awk '/^inputs:$/ { yes=1; next } yes && /^runs:$/ { exit } yes && /^  [^[:space:]][^:]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$ACTION"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = $'report-path\ndiff-cover-path\nbase-sha\nminimum\nsource-paths\nexclude-paths\nworking-directory' ] || return 1

  for input in report-path diff-cover-path base-sha minimum source-paths; do
    assert_contains "$(input_block "$input")" 'required: true' || return 1
  done
  for input in exclude-paths working-directory; do
    assert_lacks "$(input_block "$input")" 'required: true' || return 1
  done
  assert_contains "$(input_block working-directory)" 'default: .' || return 1
}

@test "coverage action has composite topology and no public outputs" {
  grep -q '^runs:$' "$ACTION" || return 1
  grep -q '^  using: composite$' "$ACTION" || return 1
  ! grep -q '^outputs:$' "$ACTION" || return 1
  ! grep -q '^  outputs:$' "$ACTION" || return 1

  evaluate="$(step_block evaluate)"
  upload="$(step_block upload)"
  finalize="$(step_block finalize)"
  assert_contains "$evaluate" 'continue-on-error: true' || return 1
  assert_contains "$evaluate" 'shell: bash' || return 1
  assert_contains "$evaluate" 'python3 "$GITHUB_ACTION_PATH/evaluate.py"' || return 1
  assert_contains "$upload" 'if: always()' || return 1
  assert_contains "$upload" 'if-no-files-found: error' || return 1
  assert_contains "$finalize" 'if: always()' || return 1
  assert_contains "$finalize" 'shell: bash' || return 1
  assert_contains "$finalize" 'python3 "$GITHUB_ACTION_PATH/finalize.py"' || return 1
}

@test "coverage action passes inputs as environment data and retains a unique artifact" {
  evaluate="$(step_block evaluate)"
  upload="$(step_block upload)"
  finalize="$(step_block finalize)"
  while IFS=' ' read -r variable input; do
    assert_contains "$evaluate" "COVERAGE_${variable}: \${{ inputs.${input} }}" || return 1
  done <<'INPUTS'
REPORT_PATH report-path
DIFF_COVER_PATH diff-cover-path
BASE_SHA base-sha
MINIMUM minimum
SOURCE_PATHS source-paths
EXCLUDE_PATHS exclude-paths
WORKING_DIRECTORY working-directory
INPUTS
  assert_contains "$evaluate" 'COVERAGE_OUTPUT_DIRECTORY: ${{ runner.temp }}/shared-coverage/${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}-${{ github.action }}' || return 1
  assert_contains "$upload" 'name: coverage-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}-${{ github.action }}' || return 1
  assert_contains "$upload" 'path: ${{ runner.temp }}/shared-coverage/${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}-${{ github.action }}' || return 1
  assert_contains "$finalize" 'COVERAGE_EVALUATE_OUTCOME: ${{ steps.evaluate.outcome }}' || return 1
  assert_contains "$finalize" 'COVERAGE_UPLOAD_OUTCOME: ${{ steps.upload.outcome }}' || return 1
  assert_contains "$finalize" 'COVERAGE_OUTPUT_DIRECTORY: ${{ runner.temp }}/shared-coverage/${{ github.run_id }}-${{ github.run_attempt }}-${{ github.job }}-${{ github.action }}' || return 1
  ! printf '%s\n' "$evaluate" "$finalize" | grep -E '^[[:space:]]*run:.*inputs\.' || return 1
}

@test "coverage action pins upload-artifact semantically and avoids provisioning" {
  upload="$(step_block upload)"
  assert_action_pin "$upload" 'actions/upload-artifact' || return 1
  runs="$(awk '/^[[:space:]]+run:/{ print }' "$ACTION")"
  for forbidden in checkout curl 'pip install' 'apt-get' 'brew install' 'eval '; do
    ! printf '%s\n' "$runs" | grep -Fq -- "$forbidden" || return 1
  done
}
