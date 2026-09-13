#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO_ROOT/scripts/revalidate-tag-release-plan.sh"
  YAML="$REPO_ROOT/.github/workflows/tag-release.yml"
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  WORKFLOW_RUN_SCRIPT="$BATS_TEST_TMPDIR/revalidate-workflow-step.sh"
  mkdir -p "$TEST_REPO" "$FAKE_BIN"

  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.name "Tag Plan Test"
  git -C "$TEST_REPO" config user.email "tag-plan@example.invalid"
  git -C "$TEST_REPO" config commit.gpgSign false
  printf 'one\n' >"$TEST_REPO/file"
  git -C "$TEST_REPO" add file
  git -C "$TEST_REPO" commit -qm "fix: baseline"
  git -C "$TEST_REPO" tag v1.2.3
  printf 'two\n' >>"$TEST_REPO/file"
  git -C "$TEST_REPO" commit -qam "fix: next"

  export PATH="$FAKE_BIN:$PATH"
  export GITHUB_REPOSITORY="example/project"
  export GH_TOKEN="test-token"
  export TAG_PREFIX="v"
  export PLANNED_SOURCE_SHA
  PLANNED_SOURCE_SHA=$(git -C "$TEST_REPO" rev-parse HEAD)
  record_snapshot
  export PLANNED_NEXT_TAG=v1.2.4
  export FAKE_MAIN_SHA="$PLANNED_SOURCE_SHA"
  export FAKE_NEXT_TAG_JSON='[]'

  cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/sh
case "$*" in
  *"/git/ref/heads/main"*)
    if [ "${FAKE_GH_FAIL_MAIN:-false}" = true ]; then
      printf 'fake gh raw main authentication diagnostic\n' >&2
      exit 1
    fi
    if [ "${FAKE_GH_BAD_MAIN:-false}" = true ]; then
      printf '{"bad":true}\n'
    else
      printf '{"object":{"type":"commit","sha":"%s"}}\n' "$FAKE_MAIN_SHA"
    fi
    ;;
  *"/git/matching-refs/tags/"*)
    if [ "${FAKE_GH_FAIL_TAGS:-false}" = true ]; then
      printf 'fake gh raw proposed-tag transport diagnostic\n' >&2
      exit 1
    fi
    printf '%s\n' "$FAKE_NEXT_TAG_JSON"
    ;;
  *)
    exit 97
    ;;
esac
SH
  chmod +x "$FAKE_BIN/gh"
}

extract_revalidation_body() {
  awk '
    $0 == "      - name: Revalidate approved release plan" { in_step=1; next }
    in_step && /^      - / { exit }
    in_step && /^        run: \|$/ { in_run=1; next }
    in_run && $0 != "" && !/^          / { exit }
    in_run { sub(/^          /, ""); print }
  ' "$YAML"
}

run_workflow_validator() {
  extract_revalidation_body >"$WORKFLOW_RUN_SCRIPT"
  run --separate-stderr bash -c 'cd "$1" && bash "$2"' \
    _ "$TEST_REPO" "$WORKFLOW_RUN_SCRIPT"
}

run_validator() {
  run --separate-stderr bash -c 'cd "$1" && "$2"' _ "$TEST_REPO" "$SCRIPT"
}

record_snapshot() {
  export PLANNED_TAG_SNAPSHOT_SHA256
  PLANNED_TAG_SNAPSHOT_SHA256=$(
    git -C "$TEST_REPO" for-each-ref --format='%(refname)%09%(objectname)' \
      "refs/tags/${TAG_PREFIX}*.*.*" | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
  )
}

@test "accepts the exact approved main and tag snapshot" {
  run_validator
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"approved release plan is still current"* ]]
}

@test "workflow revalidation normalizes an explicitly empty tag prefix" {
  export TAG_PREFIX=
  run_workflow_validator
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"approved release plan is still current"* ]]
}

@test "rejects live main drift" {
  export FAKE_MAIN_SHA=1111111111111111111111111111111111111111
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"main changed after release planning"* ]]
}

@test "rejects moving an approved lightweight tag" {
  git -C "$TEST_REPO" tag -f v1.2.3 HEAD
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects deletion of an approved matching tag" {
  git -C "$TEST_REPO" tag -d v1.2.3
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects annotated tag replacement with the same peeled commit" {
  git -C "$TEST_REPO" -c tag.gpgSign=false tag -f -a v1.2.3 HEAD~1 -m original
  record_snapshot
  local before
  before=$(git -C "$TEST_REPO" rev-parse 'v1.2.3^{commit}')
  git -C "$TEST_REPO" -c tag.gpgSign=false tag -f -a v1.2.3 HEAD~1 -m replacement
  [ "$(git -C "$TEST_REPO" rev-parse 'v1.2.3^{commit}')" = "$before" ]
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects annotated tag retargeting" {
  git -C "$TEST_REPO" -c tag.gpgSign=false tag -f -a v1.2.3 HEAD~1 -m original
  record_snapshot
  git -C "$TEST_REPO" -c tag.gpgSign=false tag -f -a v1.2.3 HEAD -m retargeted
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects a newly created tag after a first-release plan" {
  git -C "$TEST_REPO" tag -d v1.2.3
  export PLANNED_NEXT_TAG=v0.0.1
  record_snapshot
  git -C "$TEST_REPO" tag v0.0.1 HEAD~1
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects creation of a higher matching tag after planning" {
  git -C "$TEST_REPO" tag v9.0.0
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects matching tag-set drift" {
  git -C "$TEST_REPO" tag v1.2.2
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"matching tag set changed"* ]]
}

@test "rejects an existing proposed tag" {
  export FAKE_NEXT_TAG_JSON='[{"ref":"refs/tags/v1.2.4","object":{"type":"commit","sha":"1111111111111111111111111111111111111111"}}]'
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"proposed tag already exists"* ]]
}

@test "rejects malformed snapshot before any tag comparison" {
  export PLANNED_TAG_SNAPSHOT_SHA256=invalid
  run_validator
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"PLANNED_TAG_SNAPSHOT_SHA256 is not a lowercase SHA-256"* ]]
}

@test "rejects a checkout different from the approved source" {
  git -C "$TEST_REPO" checkout -q HEAD~1
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"checked-out source does not match the approved source"* ]]
}

@test "rejects malformed planned SHA before inspection" {
  export PLANNED_SOURCE_SHA=not-a-sha
  run_validator
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"PLANNED_SOURCE_SHA is not a lowercase 40-character SHA"* ]]
}

@test "fails closed when the main lookup fails" {
  export FAKE_GH_FAIL_MAIN=true
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not inspect live main"* ]]
  [[ "$stderr" != *"fake gh raw main authentication diagnostic"* ]]
}

@test "fails closed on malformed main JSON" {
  export FAKE_GH_BAD_MAIN=true
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"live main response was malformed"* ]]
}

@test "fails closed when proposed-tag lookup fails" {
  export FAKE_GH_FAIL_TAGS=true
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not inspect proposed tag"* ]]
  [[ "$stderr" != *"fake gh raw proposed-tag transport diagnostic"* ]]
}

@test "fails closed when the matching tag digest cannot be computed" {
  cat >"$FAKE_BIN/shasum" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$FAKE_BIN/shasum"
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"could not inspect matching tag set"* ]]
}

@test "fails closed on malformed proposed-tag JSON" {
  export FAKE_NEXT_TAG_JSON='{"not":"an array"}'
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"proposed-tag response was malformed"* ]]
}

@test "fails closed on a malformed member in proposed-tag results" {
  export FAKE_NEXT_TAG_JSON='[{"ref":7,"object":{}}]'
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"proposed-tag response was malformed"* ]]
}

@test "allows a well-formed nonexact prefix match" {
  export FAKE_NEXT_TAG_JSON='[{"ref":"refs/tags/v1.2.40","object":{"type":"commit","sha":"1111111111111111111111111111111111111111"}}]'
  run_validator
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"approved release plan is still current"* ]]
}

@test "accepts an unchanged first-release snapshot" {
  git -C "$TEST_REPO" tag -d v1.2.3
  export PLANNED_NEXT_TAG=v0.0.1
  record_snapshot

  run_validator
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"approved release plan is still current"* ]]
}
