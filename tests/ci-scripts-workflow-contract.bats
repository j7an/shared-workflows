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
