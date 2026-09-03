#!/usr/bin/env bats

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO_ROOT/scripts/revalidate-tag-release-plan.sh"
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
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
  export PLANNED_FIRST_RELEASE=false
  export PLANNED_LATEST_TAG=v1.2.3
  export PLANNED_LATEST_REF_SHA
  PLANNED_LATEST_REF_SHA=$(git -C "$TEST_REPO" rev-parse refs/tags/v1.2.3)
  export PLANNED_LATEST_COMMIT_SHA
  PLANNED_LATEST_COMMIT_SHA=$(git -C "$TEST_REPO" rev-parse 'v1.2.3^{commit}')
  export PLANNED_TAG_SNAPSHOT_SHA256
  PLANNED_TAG_SNAPSHOT_SHA256=$(
    git -C "$TEST_REPO" for-each-ref \
      --format='%(refname)%09%(objectname)' 'refs/tags/v*.*.*' |
      LC_ALL=C sort |
      shasum -a 256 |
      awk '{print $1}'
  )
  export PLANNED_NEXT_TAG=v1.2.4
  export FAKE_MAIN_SHA="$PLANNED_SOURCE_SHA"
  export FAKE_NEXT_TAG_JSON='[]'

  cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/sh
case "$*" in
  *"/git/ref/heads/main"*)
    [ "${FAKE_GH_FAIL_MAIN:-false}" != true ] || exit 1
    if [ "${FAKE_GH_BAD_MAIN:-false}" = true ]; then
      printf '{"bad":true}\n'
    else
      printf '{"object":{"type":"commit","sha":"%s"}}\n' "$FAKE_MAIN_SHA"
    fi
    ;;
  *"/git/matching-refs/tags/"*)
    [ "${FAKE_GH_FAIL_TAGS:-false}" != true ] || exit 1
    printf '%s\n' "$FAKE_NEXT_TAG_JSON"
    ;;
  *)
    exit 97
    ;;
esac
SH
  chmod +x "$FAKE_BIN/gh"
}

run_validator() {
  run --separate-stderr bash -c 'cd "$1" && "$2"' _ "$TEST_REPO" "$SCRIPT"
}

@test "accepts the exact approved main and tag snapshot" {
  run_validator
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

@test "rejects latest tag name drift" {
  export PLANNED_LATEST_TAG=v1.2.2
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"highest matching tag changed"* ]]
}

@test "rejects latest raw ref drift" {
  export PLANNED_LATEST_REF_SHA=2222222222222222222222222222222222222222
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"latest tag ref changed"* ]]
}

@test "rejects latest peeled commit drift" {
  export PLANNED_LATEST_COMMIT_SHA=3333333333333333333333333333333333333333
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"latest tag target changed"* ]]
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

@test "rejects a changed first-release state" {
  export PLANNED_FIRST_RELEASE=true
  export PLANNED_LATEST_TAG=
  export PLANNED_LATEST_REF_SHA=
  export PLANNED_LATEST_COMMIT_SHA=
  run_validator
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"first-release state changed"* ]]
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
  export PLANNED_FIRST_RELEASE=true
  export PLANNED_LATEST_TAG=
  export PLANNED_LATEST_REF_SHA=
  export PLANNED_LATEST_COMMIT_SHA=
  export PLANNED_TAG_SNAPSHOT_SHA256
  PLANNED_TAG_SNAPSHOT_SHA256=$(
    git -C "$TEST_REPO" for-each-ref \
      --format='%(refname)%09%(objectname)' 'refs/tags/v*.*.*' |
      LC_ALL=C sort |
      shasum -a 256 |
      awk '{print $1}'
  )

  run_validator
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"approved release plan is still current"* ]]
}
