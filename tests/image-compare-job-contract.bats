#!/usr/bin/env bats

load helpers/action-pin-assertions

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

WF=.github/workflows/dependency-safety.yml

@test "image-compare permissions are exactly contents read and pull-requests read" {
  run yq -o=json -I=0 '.jobs.image-compare.permissions' "$WF"
  [ "$status" -eq 0 ]
  [ "$output" = '{"contents":"read","pull-requests":"read"}' ]
}

@test "image-compare runs only for dependabot" {
  run yq '.jobs.image-compare.if' "$WF"
  [ "$output" = "github.event.pull_request.user.login == 'dependabot[bot]'" ]
}

@test "harden-runner is the first step of image-compare" {
  local step
  step=$(yq '.jobs.image-compare.steps[0]' "$WF")
  assert_action_pin "$step" "step-security/harden-runner"
}

@test "no step that runs trivy has GH_TOKEN or github.token in env" {
  local id body
  for id in install compare; do
    [ "$(yq ".jobs.image-compare.steps[] | select(.id == \"$id\") | .env | has(\"GH_TOKEN\")" "$WF")" = "false" ]
    body=$(yq ".jobs.image-compare.steps[] | select(.id == \"$id\")" "$WF")
    ! grep -q 'github\.token' <<<"$body"
    ! grep -q 'secrets\.' <<<"$body"
  done
}

@test "Trivy pin is semver and 64 lowercase hex, and the install step verifies the checksum before extracting" {
  local step ver sha run
  step='.jobs.image-compare.steps[] | select(.id == "install")'
  ver=$(yq "$step | .env.TRIVY_VERSION" "$WF")
  sha=$(yq "$step | .env.TRIVY_SHA256" "$WF")
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  [[ $sha =~ ^[0-9a-f]{64}$ ]]
  run=$(yq "$step | .run" "$WF")
  grep -q 'sha256sum -c' <<<"$run"
  grep -q 'tar ' <<<"$run"
  local c_line t_line
  c_line=$(grep -n 'sha256sum -c' <<<"$run" | head -1 | cut -d: -f1)
  t_line=$(grep -n 'tar ' <<<"$run" | head -1 | cut -d: -f1)
  [ "$c_line" -lt "$t_line" ]
}

@test "image-compare does not use actions/checkout and not trivy-action" {
  local uses
  uses=$(yq '.jobs.image-compare.steps[].uses // ""' "$WF")
  ! grep -q 'actions/checkout' <<<"$uses"
  ! grep -q 'trivy-action' <<<"$uses"
}

@test "scan needs image-compare and runs unless cancelled" {
  [ "$(yq '.jobs.scan.needs' "$WF")" = "image-compare" ]
  [ "$(yq '.jobs.scan.if' "$WF")" = '${{ !cancelled() }}' ]
}

@test "scan step receives image-compare result and output via env only" {
  local env_res env_out hits
  env_res=$(yq '.jobs.scan.steps[] | select(.name == "Scan and report") | .env.IMAGE_COMPARE_RESULT' "$WF")
  env_out=$(yq '.jobs.scan.steps[] | select(.name == "Scan and report") | .env.IMAGE_COMPARE_OUTPUT' "$WF")
  [ "$env_res" = '${{ needs.image-compare.result }}' ]
  [ "$env_out" = '${{ needs.image-compare.outputs.result }}' ]
  hits=$(yq '.jobs[].steps[] | select(.run != null) | select(.run | test("needs\.image-compare")) | .name' "$WF")
  [ -z "$hits" ]
}
