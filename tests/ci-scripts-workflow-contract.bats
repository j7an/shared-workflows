#!/usr/bin/env bats
# ci-scripts-workflow-contract.bats - static contracts for the repository's
# script-test workflow.

. "$BATS_TEST_DIRNAME/helpers/action-pin-assertions.bash"

YAML=".github/workflows/ci-scripts.yml"

step_block() {
  awk -v name="      - name: $1" '
    $0 == name { flag=1; print; next }
    flag && /^      - / { exit }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  ' "$YAML"
}

step_input() {
  step_block "Install bats" | awk -v key="          $1:" '
    index($0, key) == 1 {
      sub(/^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*/, "")
      print
      exit
    }
  '
}

@test "Bats setup authenticates downloads and pins a stable version" {
  block=$(step_block "Install bats")
  assert_action_pin "$block" "bats-core/bats-action"

  [ "$(step_input github-token)" = '${{ github.token }}' ]

  version=$(step_input bats-version)
  version=${version#\"}
  version=${version%\"}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "Bats setup disables unused helper libraries" {
  for input in support-install assert-install detik-install file-install; do
    [ "$(step_input "$input")" = "false" ]
  done
}

@test "coverage action changes run the test workflow with the supported tool range" {
  grep -Fq -- "- 'actions/coverage/**'" "$YAML" || return 1

  block=$(step_block "Install current diff-cover")
  [[ "$block" == *'python3 --version'* ]] || return 1
  [[ "$block" == *'python3 -m venv "$RUNNER_TEMP/diff-cover-current"'* ]] || return 1
  [[ "$block" == *"'diff-cover>=10.2,<11'"* ]] || return 1
  [[ "$block" == *'DIFF_COVER_PATH='* ]] || return 1
  [[ "$block" == *'$GITHUB_ENV'* ]] || return 1
}

@test "coverage compatibility job runs the action tests against the lower supported release" {
  block=$(awk '
    /^  coverage-compatibility:$/ { found = 1 }
    found { print }
    found && /^  [A-Za-z0-9_-]+:$/ && $0 != "  coverage-compatibility:" { exit }
  ' "$YAML")
  [[ "$block" == *'runs-on: ubuntu-latest'* ]] || return 1
  assert_action_pin "$block" "step-security/harden-runner" || return 1
  assert_action_pin "$block" "actions/checkout" || return 1
  assert_action_pin "$block" "bats-core/bats-action" || return 1
  [[ "$block" == *'python3 -m venv "$RUNNER_TEMP/diff-cover-10.2.0"'* ]] || return 1
  [[ "$block" == *"'diff-cover==10.2.0'"* ]] || return 1
  [[ "$block" == *'DIFF_COVER_PATH='* ]] || return 1
  [[ "$block" == *'bats tests/coverage-action.bats'* ]] || return 1
}
