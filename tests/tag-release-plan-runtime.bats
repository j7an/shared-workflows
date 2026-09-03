#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  YAML="$REPO_ROOT/.github/workflows/tag-release.yml"
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  RUN_SCRIPT="$BATS_TEST_TMPDIR/compute-release-plan.sh"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
}

extract_compute_body() {
  awk '
    $0 == "      - name: Compute release plan" { in_step=1; next }
    in_step && /^      - / { exit }
    in_step && /^        run: \|$/ { in_run=1; next }
    in_run && $0 != "" && !/^          / { exit }
    in_run { sub(/^          /, ""); print }
  ' "$YAML"
}

write_run_script() {
  {
    echo "set -euo pipefail"
    extract_compute_body
  } >"$RUN_SCRIPT"
}

init_repo() {
  mkdir -p "$TEST_REPO"
  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.name "Plan Runtime"
  git -C "$TEST_REPO" config user.email "plan@example.invalid"
  git -C "$TEST_REPO" config commit.gpgSign false
}

make_history() {
  subject=$1
  tag=${2:-v1.2.3}
  init_repo
  printf 'base\n' >"$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -qm "fix: baseline"
  git -C "$TEST_REPO" tag "$tag"
  printf 'next\n' >>"$TEST_REPO/file"
  git -C "$TEST_REPO" commit -qam "$subject"
}

run_plan() {
  choice=$1
  prefix=$2
  write_run_script
  source_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
  run --separate-stderr bash -c \
    'cd "$1" && CHOICE="$2" TAG_PREFIX="$3" GITHUB_SHA="$4" GITHUB_OUTPUT="$5" GITHUB_STEP_SUMMARY="$6" bash "$7"' \
    _ "$TEST_REPO" "$choice" "$prefix" "$source_sha" \
    "$GITHUB_OUTPUT" "$GITHUB_STEP_SUMMARY" "$RUN_SCRIPT"
}

assert_snapshot_outputs() {
  grep -qE '^source_sha=[0-9a-f]{40}$' "$GITHUB_OUTPUT"
  grep -qE '^latest_ref_sha=([0-9a-f]{40})?$' "$GITHUB_OUTPUT"
  grep -qE '^latest_commit_sha=([0-9a-f]{40})?$' "$GITHUB_OUTPUT"
  grep -qE '^tag_snapshot_sha256=[0-9a-f]{64}$' "$GITHUB_OUTPUT"
  grep -q "^### Release " "$GITHUB_STEP_SUMMARY"
  source_sha=$(sed -n 's/^source_sha=//p' "$GITHUB_OUTPUT")
  latest_commit_sha=$(sed -n 's/^latest_commit_sha=//p' "$GITHUB_OUTPUT")
  grep -qF "**Source commit:** \`$source_sha\`" "$GITHUB_STEP_SUMMARY"
  if [ -n "$latest_commit_sha" ]; then
    grep -qF "**Previous tag commit:** \`$latest_commit_sha\`" \
      "$GITHUB_STEP_SUMMARY"
  else
    grep -qF '**Previous tag commit:** _none (first release)_' \
      "$GITHUB_STEP_SUMMARY"
  fi
}

@test "auto patch proposes v1.2.4" {
  make_history "fix: correct behavior"
  run_plan auto v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v1.2.4" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `patch` -' "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs
}

@test "auto minor proposes v1.3.0" {
  make_history "feat: add behavior"
  run_plan auto v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v1.3.0" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `minor` -' "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs
}

@test "auto major proposes v2.0.0" {
  make_history "feat!: change contract"
  run_plan auto v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v2.0.0" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `major` -' "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs
}

@test "explicit override is proposed and warned about" {
  make_history "feat!: change contract"
  run_plan patch v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v1.2.4" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `major` -' "$GITHUB_STEP_SUMMARY"
  grep -q "Operator override" "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs
}

@test "custom prefix remains isolated" {
  make_history "fix: tools patch" "tools/v1.2.3"
  run_plan auto tools/v
  [ "$status" -eq 0 ]
  grep -qx "latest_tag=tools/v1.2.3" "$GITHUB_OUTPUT"
  grep -qx "next_tag=tools/v1.2.4" "$GITHUB_OUTPUT"
  assert_snapshot_outputs
}

@test "first release records empty prior-tag witnesses" {
  init_repo
  printf 'first\n' >"$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -qm "fix: first"
  run_plan auto v
  [ "$status" -eq 0 ]
  grep -qx "first_release=true" "$GITHUB_OUTPUT"
  grep -qx "latest_tag=" "$GITHUB_OUTPUT"
  grep -qx "latest_ref_sha=" "$GITHUB_OUTPUT"
  grep -qx "latest_commit_sha=" "$GITHUB_OUTPUT"
  grep -qx "next_tag=v0.0.1" "$GITHUB_OUTPUT"
  assert_snapshot_outputs
}

@test "invalid prefix fails before outputs" {
  make_history "fix: next"
  run_plan auto 'bad*'
  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "no commits after latest tag fails without a proposal" {
  init_repo
  printf 'base\n' >"$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -qm "fix: baseline"
  git -C "$TEST_REPO" tag v1.2.3
  run_plan auto v
  [ "$status" -ne 0 ]
  ! grep -q '^next_tag=' "$GITHUB_OUTPUT"
}
