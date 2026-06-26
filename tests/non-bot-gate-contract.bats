#!/usr/bin/env bats
# non-bot-gate-contract.bats - static contract tests for the reusable
# dependency-safety non-bot gate workflow.

YAML=".github/workflows/dependency-safety-non-bot-gate.yml"

extract_on_block() {
  awk '
    /^on:$/ { flag=1; print; next }
    flag && /^[^[:space:]][^:]*:/ { exit }
    flag { print }
  ' "$YAML"
}

extract_gate_job_block() {
  awk '
    /^  gate:$/ { flag=1; print; next }
    flag && /^  [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  ' "$YAML"
}

extract_job_permissions_block() {
  extract_gate_job_block | awk '
    /^    permissions:$/ { flag=1; next }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  '
}

extract_run_block() {
  awk '
    /^      - name: Post dependency-safety gate status$/ { in_step = 1 }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run && /^      - name: / { exit }
    in_run { print }
  ' "$YAML" | sed -E 's/^          //'
}

non_comment_content() {
  sed '/^[[:space:]]*#/d' "$YAML"
}

@test "workflow is reusable only: workflow_call trigger and no pull_request_target trigger" {
  block=$(extract_on_block)
  [[ "$block" == *"workflow_call:"* ]]
  [[ "$block" != *"pull_request_target:"* ]]
}

@test "non-comment workflow logic does not use github.actor" {
  if non_comment_content | grep -q "github.actor"; then
    echo "github.actor must not be used as workflow logic"
    return 1
  fi
}

@test "gate job uses pull_request.user.login complement of scanner caller" {
  grep -qF "if: github.event.pull_request.user.login != 'dependabot[bot]'" "$YAML"
}

@test "gate job requests exactly statuses: write" {
  [ "$(extract_job_permissions_block | sed '/^[[:space:]]*#/d')" = "      statuses: write" ]
}

@test "status post uses canonical context, description, and caller run target_url" {
  grep -qF -- '-f context="dependency-safety / gate"' "$YAML"
  grep -qF -- '-f description="Non-bot PR: dependency-safety scan not required"' "$YAML"
  grep -qF -- '-f target_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"' "$YAML"
}

@test "workflow has no checkout and no third-party action steps" {
  if grep -qF "actions/checkout" "$YAML"; then
    echo "checkout is forbidden in the status-only gate"
    return 1
  fi

  if grep -Eq '^[[:space:]]+-[[:space:]]+uses:' "$YAML"; then
    echo "third-party action steps are forbidden in the status-only gate"
    return 1
  fi
}

@test "run block does not interpolate PR event context directly" {
  block=$(extract_run_block)
  [[ "$block" != *'${{ github.event.pull_request'* ]]
}
