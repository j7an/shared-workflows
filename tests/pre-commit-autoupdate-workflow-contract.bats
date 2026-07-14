#!/usr/bin/env bats
# pre-commit-autoupdate-workflow-contract.bats - static contract tests for the
# reusable pre-commit autoupdate workflow.

. "$BATS_TEST_DIRNAME/helpers/action-pin-assertions.bash"

YAML=".github/workflows/pre-commit-autoupdate.yml"
WORKFLOW_README=".github/workflows/README.md"
ROOT_README="README.md"

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$2" "$1"
    return 1
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *)
      printf 'expected text to contain:\n%s\n' "$2"
      return 1
      ;;
  esac
}

assert_lacks() {
  case "$1" in
    *"$2"*)
      printf 'expected text not to contain:\n%s\n' "$2"
      return 1
      ;;
    *) return 0 ;;
  esac
}

on_block() {
  awk '
    /^on:$/ { flag=1; print; next }
    flag && /^[^[:space:]][^:]*:/ { exit }
    flag { print }
  ' "$YAML"
}

on_trigger_keys() {
  on_block | awk '
    /^  [A-Za-z0-9_-]+:$/ {
      sub(/^  /, "", $0);
      sub(/:$/, "", $0);
      print
    }
  '
}

workflow_call_input_keys() {
  on_block | awk '
    /^  workflow_call:$/ { in_call=1; next }
    in_call && /^    inputs:$/ { in_inputs=1; next }
    in_inputs && /^      [a-z0-9_]+:$/ {
      sub(/^      /, "", $0);
      sub(/:$/, "", $0);
      print;
      next
    }
    in_inputs && /^    [A-Za-z0-9_-]+:/ { exit }
  '
}

input_block() {
  awk -v key="      $1:" '
    $0 == key { flag=1; print; next }
    flag && /^      [a-z0-9_]+:$/ { exit }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag && /^  [A-Za-z0-9_-]+:/ { exit }
    flag && /^[^[:space:]][^:]*:/ { exit }
    flag { print }
  ' "$YAML"
}

input_type() {
  input_block "$1" | awk '/^        type:/ { sub(/^        type: */, ""); print; exit }'
}

input_default() {
  input_block "$1" | awk '/^        default:/ { sub(/^        default: */, ""); print; exit }'
}

secret_block() {
  on_block | awk -v key="      $1:" '
    /^    secrets:$/ { in_secrets=1; next }
    in_secrets && $0 == key { flag=1; print; next }
    flag && /^      [A-Z0-9_]+:$/ { exit }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  '
}

job_block() {
  awk -v job="  $1:" '
    $0 == job { flag=1; print; next }
    flag && /^  [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  ' "$YAML"
}

step_block() {
  awk -v name="      - name: $1" '
    $0 == name { flag=1; print; next }
    flag && /^      - / { exit }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  ' "$YAML"
}

job_permissions_block() {
  job_block "$1" | awk '
    /^    permissions:/ { flag=1; print; next }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  '
}

run_blocks() {
  awk '
    /^        run: \|$/ { in_run=1; next }
    in_run && /^      - / { in_run=0; next }
    in_run && /^    [A-Za-z0-9_-]+:/ { in_run=0; next }
    in_run { print }
  ' "$YAML"
}

workflow_readme_section() {
  awk '
    /^## `pre-commit-autoupdate.yml`$/ { flag=1; print; next }
    flag && /^## `/ { exit }
    flag { print }
  ' "$WORKFLOW_README"
}

root_readme_section() {
  awk '
    /^## Pre-commit Autoupdate$/ { flag=1; print; next }
    flag && /^## / { exit }
    flag { print }
  ' "$ROOT_README"
}

@test "pre-commit-autoupdate.yml is workflow_call only" {
  assert_eq "$(on_trigger_keys)" "workflow_call"
}

@test "public inputs and defaults match the v1 contract" {
  expected_inputs=$'branch
commit_message
config_path
labels
pre_commit_version
restrict_paths
sign_commits
title'

  observed_inputs=$(workflow_call_input_keys | sort)
  expected_sorted=$(printf "%s\n" "$expected_inputs" | sort)
  assert_eq "$observed_inputs" "$expected_sorted"

  assert_eq "$(input_type config_path)" "string"
  assert_eq "$(input_default config_path)" '".pre-commit-config.yaml"'
  assert_eq "$(input_type branch)" "string"
  assert_eq "$(input_default branch)" '"deps/pre-commit-autoupdate"'
  assert_eq "$(input_type title)" "string"
  assert_eq "$(input_default title)" '"deps: update pre-commit hooks"'
  assert_eq "$(input_type commit_message)" "string"
  assert_eq "$(input_default commit_message)" '"deps: update pre-commit hooks"'
  assert_eq "$(input_type labels)" "string"
  assert_eq "$(input_default labels)" '"dependencies"'
  assert_eq "$(input_type sign_commits)" "boolean"
  assert_eq "$(input_default sign_commits)" "true"
  assert_eq "$(input_type restrict_paths)" "boolean"
  assert_eq "$(input_default restrict_paths)" "true"
  assert_eq "$(input_type pre_commit_version)" "string"
  assert_eq "$(input_default pre_commit_version)" '""'
}

@test "Release Bot private key secret is optional" {
  block=$(secret_block RELEASE_BOT_PRIVATE_KEY)
  assert_contains "$block" "required: false"
}

@test "workflow denies permissions at top level and declares the job write union" {
  grep -qxF "permissions: {}" "$YAML"
  assert_eq "$(job_permissions_block autoupdate)" $'    permissions:\n      contents: write\n      pull-requests: write'
}

@test "single-instance third-party actions use semantic pins" {
  block=$(job_block autoupdate)
  for target in \
    step-security/harden-runner \
    actions/create-github-app-token \
    actions/checkout \
    astral-sh/setup-uv; do
    assert_action_pin "$block" "$target"
  done
}

@test "App token minting is conditional and requests contents plus pull-requests write" {
  block=$(step_block "Mint GitHub App token")
  assert_contains "$block" "if: steps.preflight.outputs.auth_mode == 'app'"
  assert_contains "$block" 'client-id: ${{ vars.RELEASE_BOT_APP_ID }}'
  assert_contains "$block" 'private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}'
  assert_contains "$block" "permission-contents: write"
  assert_contains "$block" "permission-pull-requests: write"
}

@test "checkout does not persist credentials" {
  block=$(step_block "Checkout repository")
  assert_action_pin "$block" "actions/checkout"
  assert_contains "$block" "persist-credentials: false"
}

@test "preflight computes private-key presence without passing the secret to the script" {
  block=$(step_block "Preflight inputs and auth")
  assert_contains "$block" 'APP_PRIVATE_KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}'
  assert_contains "$block" "unset APP_PRIVATE_KEY"
  assert_contains "$block" "HAS_APP_PRIVATE_KEY=true"
  assert_contains "$block" "HAS_APP_PRIVATE_KEY=false"
  assert_contains "$block" 'pre_commit_autoupdate_preflight >> "$GITHUB_OUTPUT"'
}

@test "run blocks do not interpolate raw workflow inputs" {
  runs=$(run_blocks)
  assert_lacks "$runs" '${{ inputs.'
}

@test "shell steps bind validated preflight outputs after preflight" {
  run_block=$(step_block "Run pre-commit autoupdate")
  diff_block=$(step_block "Check for changes")

  assert_contains "$run_block" 'USE_PINNED_PRE_COMMIT: ${{ steps.preflight.outputs.use_pinned_pre_commit }}'
  assert_contains "$run_block" 'PRE_COMMIT_VERSION: ${{ steps.preflight.outputs.pre_commit_version }}'
  assert_contains "$run_block" 'CONFIG_PATH: ${{ steps.preflight.outputs.config_path }}'
  assert_contains "$diff_block" 'CONFIG_PATH: ${{ steps.preflight.outputs.config_path }}'
  assert_lacks "$run_block" 'PRE_COMMIT_VERSION: ${{ inputs.pre_commit_version }}'
  assert_lacks "$run_block" 'CONFIG_PATH: ${{ inputs.config_path }}'
  assert_lacks "$diff_block" 'CONFIG_PATH: ${{ inputs.config_path }}'
}

@test "uvx commands are fixed workflow branches, not emitted command strings" {
  block=$(step_block "Run pre-commit autoupdate")
  assert_contains "$block" 'if [ "$USE_PINNED_PRE_COMMIT" = "true" ]; then'
  assert_contains "$block" 'uvx --from "pre-commit==$PRE_COMMIT_VERSION" pre-commit autoupdate -c "$CONFIG_PATH"'
  assert_contains "$block" 'uvx pre-commit autoupdate -c "$CONFIG_PATH"'
  assert_lacks "$block" "eval"
}

@test "change detection is set -e safe and gates PR creation" {
  block=$(step_block "Check for changes")
  assert_contains "$block" 'if git diff --quiet -- "$CONFIG_PATH"; then'
  assert_contains "$block" 'echo "changed=false" >> "$GITHUB_OUTPUT"'
  assert_contains "$block" 'echo "changed=true" >> "$GITHUB_OUTPUT"'

  restricted=$(step_block "Open restricted PR with updates")
  unrestricted=$(step_block "Open unrestricted PR with updates")
  assert_contains "$restricted" "steps.diff.outputs.changed == 'true'"
  assert_contains "$unrestricted" "steps.diff.outputs.changed == 'true'"
}

@test "pull request creation has restricted and unrestricted path variants" {
  restricted=$(step_block "Open restricted PR with updates")
  unrestricted=$(step_block "Open unrestricted PR with updates")

  assert_action_pin "$restricted" "peter-evans/create-pull-request"
  assert_action_pin "$unrestricted" "peter-evans/create-pull-request"
  assert_contains "$restricted" "inputs.restrict_paths"
  assert_contains "$restricted" 'add-paths: ${{ inputs.config_path }}'
  assert_contains "$restricted" "delete-branch: true"
  assert_contains "$restricted" 'token: ${{ steps.app-token.outputs.token || github.token }}'
  assert_contains "$restricted" 'body: ${{ steps.pr-body.outputs.body }}'

  assert_contains "$unrestricted" "!inputs.restrict_paths"
  assert_lacks "$unrestricted" "add-paths:"
  assert_contains "$unrestricted" "delete-branch: true"
  assert_contains "$unrestricted" 'token: ${{ steps.app-token.outputs.token || github.token }}'
  assert_contains "$unrestricted" 'body: ${{ steps.pr-body.outputs.body }}'
}

@test "PR body caveat is conditional on fallback auth" {
  block=$(step_block "Compose pull request body")
  assert_contains "$block" 'USE_FALLBACK_CAVEAT: ${{ steps.preflight.outputs.use_fallback_caveat }}'
  assert_contains "$block" 'if [ "$USE_FALLBACK_CAVEAT" = "true" ]; then'
  assert_contains "$block" "GITHUB_TOKEN-authored PRs may not trigger required CI automatically"
}

@test "docs cover App and fallback callers plus operational caveats" {
  workflow_docs=$(workflow_readme_section)
  root_docs=$(root_readme_section)

  assert_contains "$workflow_docs" "Recommended App-token caller"
  assert_contains "$workflow_docs" "Minimal GITHUB_TOKEN fallback caller"
  assert_contains "$workflow_docs" "RELEASE_BOT_PRIVATE_KEY: \${{ secrets.RELEASE_BOT_PRIVATE_KEY }}"
  assert_contains "$workflow_docs" "contents: read"
  assert_contains "$workflow_docs" "pull-requests: write"
  assert_contains "$workflow_docs" "GITHUB_TOKEN-authored PRs may not trigger required CI automatically"
  assert_contains "$workflow_docs" "pre_commit_version"
  assert_contains "$workflow_docs" "restrict_paths"
  assert_contains "$workflow_docs" "403"
  assert_contains "$workflow_docs" "caller keeps its own schedule"

  assert_contains "$root_docs" "pre-commit-autoupdate.yml"
  assert_contains "$root_docs" "uvx"
  assert_contains "$root_docs" "App-token"
  assert_contains "$root_docs" "GITHUB_TOKEN"
}
