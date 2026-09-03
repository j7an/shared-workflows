#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

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
  git -C "$TEST_REPO" tag -am "release $tag" "$tag"
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

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

assert_snapshot_outputs() {
  local prefix expected_source_sha expected_first_release expected_latest_tag
  local expected_latest_ref_sha expected_latest_commit_sha expected_snapshot_sha256
  prefix=${1:-v}
  expected_source_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
  expected_latest_tag=$(
    git -C "$TEST_REPO" tag -l "${prefix}*.*.*" --sort=-version:refname |
      sed -n '1p'
  )
  if [ -n "$expected_latest_tag" ]; then
    expected_first_release=false
    expected_latest_ref_sha=$(
      git -C "$TEST_REPO" rev-parse "refs/tags/$expected_latest_tag"
    )
    expected_latest_commit_sha=$(
      git -C "$TEST_REPO" rev-parse "$expected_latest_tag^{commit}"
    )
  else
    expected_first_release=true
    expected_latest_ref_sha=
    expected_latest_commit_sha=
  fi
  expected_snapshot_sha256=$(
    git -C "$TEST_REPO" for-each-ref \
      --format='%(refname)%09%(objectname)' "refs/tags/${prefix}*.*.*" |
      LC_ALL=C sort |
      shasum -a 256 |
      awk '{print $1}'
  )

  grep -qE '^source_sha=[0-9a-f]{40}$' "$GITHUB_OUTPUT"
  grep -qE '^first_release=(true|false)$' "$GITHUB_OUTPUT"
  grep -qE '^latest_ref_sha=([0-9a-f]{40})?$' "$GITHUB_OUTPUT"
  grep -qE '^latest_commit_sha=([0-9a-f]{40})?$' "$GITHUB_OUTPUT"
  grep -qE '^tag_snapshot_sha256=[0-9a-f]{64}$' "$GITHUB_OUTPUT"
  [ "$(output_value source_sha)" = "$expected_source_sha" ]
  [ "$(output_value first_release)" = "$expected_first_release" ]
  [ "$(output_value latest_tag)" = "$expected_latest_tag" ]
  [ "$(output_value latest_ref_sha)" = "$expected_latest_ref_sha" ]
  [ "$(output_value latest_commit_sha)" = "$expected_latest_commit_sha" ]
  [ "$(output_value tag_snapshot_sha256)" = "$expected_snapshot_sha256" ]
  grep -q "^### Release " "$GITHUB_STEP_SUMMARY"
  grep -qF "**Source commit:** \`$expected_source_sha\`" "$GITHUB_STEP_SUMMARY"
  if [ -n "$expected_latest_commit_sha" ]; then
    grep -qF "**Previous tag commit:** \`$expected_latest_commit_sha\`" \
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
  assert_snapshot_outputs v
}

@test "auto minor proposes v1.3.0" {
  make_history "feat: add behavior"
  run_plan auto v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v1.3.0" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `minor` -' "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs v
}

@test "auto major proposes v2.0.0" {
  make_history "feat!: change contract"
  run_plan auto v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v2.0.0" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `major` -' "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs v
}

@test "explicit override is proposed and warned about" {
  make_history "feat!: change contract"
  run_plan patch v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v1.2.4" "$GITHUB_OUTPUT"
  grep -qF '**Analysis would have picked:** `major` -' "$GITHUB_STEP_SUMMARY"
  grep -q "Operator override" "$GITHUB_STEP_SUMMARY"
  assert_snapshot_outputs v
}

@test "explicit bump matching analysis is proposed without an override warning" {
  make_history "feat: add behavior"
  run_plan minor v
  [ "$status" -eq 0 ]
  grep -qx "next_tag=v1.3.0" "$GITHUB_OUTPUT"
  grep -qF '**Input:** `minor` -> explicit: **minor** (matches analysis)' \
    "$GITHUB_STEP_SUMMARY"
  grep -qF '**Analysis would have picked:** `minor` -' "$GITHUB_STEP_SUMMARY"
  run grep -q "Operator override" "$GITHUB_STEP_SUMMARY"
  [ "$status" -ne 0 ]
  assert_snapshot_outputs v
}

@test "custom prefix remains isolated" {
  make_history "fix: tools patch" "tools/v1.2.3"
  run_plan auto tools/v
  [ "$status" -eq 0 ]
  grep -qx "latest_tag=tools/v1.2.3" "$GITHUB_OUTPUT"
  grep -qx "next_tag=tools/v1.2.4" "$GITHUB_OUTPUT"
  assert_snapshot_outputs tools/v
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
  assert_snapshot_outputs v
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
