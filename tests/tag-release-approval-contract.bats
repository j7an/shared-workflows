#!/usr/bin/env bats

. "$BATS_TEST_DIRNAME/helpers/action-pin-assertions.bash"

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  YAML="$REPO_ROOT/.github/workflows/tag-release.yml"
}

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

@test "workflow preserves its public inputs secret and created-tag output" {
  on=$(on_block)
  assert_contains "$on" "      bump:"
  assert_contains "$on" "      tag-prefix:"
  assert_contains "$on" "      RELEASE_BOT_PRIVATE_KEY:"
  assert_contains "$on" 'value: ${{ jobs.release.outputs.tag }}'
  assert_lacks "$on" "proposed_tag:"
  assert_lacks "$on" "expected-tag:"
}

@test "plan is read-only and precedes the gated release job" {
  grep -qxF "permissions: {}" "$YAML"
  assert_eq "$(job_permissions_block plan)" $'    permissions:\n      contents: read'
  plan=$(job_block plan)
  release=$(job_block release)
  assert_lacks "$plan" "environment:"
  assert_lacks "$plan" "RELEASE_BOT_PRIVATE_KEY"
  assert_lacks "$plan" "create-github-app-token"
  assert_contains "$release" "needs: plan"
  assert_contains "$release" 'name: Approve and create ${{ needs.plan.outputs.next_tag }}'
  assert_contains "$release" "environment: release"
  assert_eq "$(job_permissions_block release)" $'    permissions:\n      contents: read'
}

@test "both checkouts are read-only and persist no credential" {
  for job in plan release; do
    block=$(job_block "$job")
    assert_action_pin "$block" "actions/checkout"
    assert_contains "$block" "fetch-depth: 0"
    assert_contains "$block" "fetch-tags: true"
    assert_contains "$block" "persist-credentials: false"
    assert_lacks "$block" 'token: ${{ steps.app-token.outputs.token }}'
  done
}

@test "App credential appears only in the gated release job" {
  plan=$(job_block plan)
  release=$(job_block release)
  assert_lacks "$plan" 'private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}'
  assert_contains "$release" 'private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}'
  assert_contains "$release" "permission-contents: write"
  assert_action_pin "$release" "actions/create-github-app-token"
}

@test "revalidation binds every approved plan witness without App credentials" {
  block=$(step_block "Revalidate approved release plan")
  assert_contains "$block" 'GH_TOKEN: ${{ github.token }}'
  assert_lacks "$block" 'steps.app-token.outputs.token'
  assert_lacks "$block" 'RELEASE_BOT_PRIVATE_KEY'
  assert_contains "$block" 'TAG_PREFIX: ${{ inputs.tag-prefix }}'
  assert_contains "$block" 'PLANNED_SOURCE_SHA: ${{ needs.plan.outputs.source_sha }}'
  assert_contains "$block" 'PLANNED_FIRST_RELEASE: ${{ needs.plan.outputs.first_release }}'
  assert_contains "$block" 'PLANNED_LATEST_TAG: ${{ needs.plan.outputs.latest_tag }}'
  assert_contains "$block" 'PLANNED_LATEST_REF_SHA: ${{ needs.plan.outputs.latest_ref_sha }}'
  assert_contains "$block" 'PLANNED_LATEST_COMMIT_SHA: ${{ needs.plan.outputs.latest_commit_sha }}'
  assert_contains "$block" 'PLANNED_TAG_SNAPSHOT_SHA256: ${{ needs.plan.outputs.tag_snapshot_sha256 }}'
  assert_contains "$block" 'PLANNED_NEXT_TAG: ${{ needs.plan.outputs.next_tag }}'
}

@test "revalidation precedes credentials and every mutation" {
  release=$(job_block release)
  validate_line=$(printf '%s\n' "$release" | grep -nF -- \
    '- name: Revalidate approved release plan' | cut -d: -f1)
  mint_line=$(printf '%s\n' "$release" | grep -nF -- \
    '- name: Mint GitHub App token' | cut -d: -f1)
  bump_line=$(printf '%s\n' "$release" | grep -nF -- \
    '- name: Bump version files' | cut -d: -f1)
  tag_line=$(printf '%s\n' "$release" | grep -nF -- \
    '- name: Create and push tag' | cut -d: -f1)
  [ -n "$validate_line" ]
  [ -n "$mint_line" ]
  [ -n "$bump_line" ]
  [ -n "$tag_line" ]
  [ "$validate_line" -lt "$mint_line" ]
  [ "$mint_line" -lt "$bump_line" ]
  [ "$bump_line" -lt "$tag_line" ]
}

@test "mutation steps consume the planned tag without recomputation" {
  for name in "Bump version files" "Create and push tag"; do
    block=$(step_block "$name")
    assert_contains "$block" 'NEXT_TAG: ${{ needs.plan.outputs.next_tag }}'
    assert_lacks "$block" 'steps.compute.outputs.next_tag'
  done
  assert_lacks "$(job_block release)" "Compute release plan"
}

@test "created-tag output is written only after the ref POST" {
  body=$(step_block "Create and push tag")
  post_line=$(printf '%s\n' "$body" | grep -nF \
    'gh api -X POST "repos/${REPO}/git/refs"' | cut -d: -f1)
  output_line=$(printf '%s\n' "$body" | grep -nF \
    'echo "tag=${NEXT_TAG}" >> "$GITHUB_OUTPUT"' | cut -d: -f1)
  [ -n "$post_line" ]
  [ -n "$output_line" ]
  [ "$output_line" -gt "$post_line" ]
}

@test "final live-main equality check precedes tag creation" {
  body=$(step_block "Create and push tag")
  check_line=$(printf '%s\n' "$body" | grep -nF \
    '[ "$LIVE_MAIN_SHA" != "$TAG_TARGET_SHA" ]' | cut -d: -f1)
  post_line=$(printf '%s\n' "$body" | grep -nF \
    'gh api -X POST "repos/${REPO}/git/refs"' | cut -d: -f1)
  [ -n "$check_line" ]
  [ -n "$post_line" ]
  [ "$check_line" -lt "$post_line" ]
}
