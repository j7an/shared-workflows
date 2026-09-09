#!/usr/bin/env bats

setup() {
  YAML="$BATS_TEST_DIRNAME/../.github/workflows/tag-release.yml"
  export TEST_STATE="$BATS_TEST_TMPDIR"
  export PLANNED_SOURCE_SHA=1111111111111111111111111111111111111111
  export TAG_TARGET_SHA=2222222222222222222222222222222222222222
  export GITHUB_REPOSITORY=example/project NEXT_TAG=v1.2.4
  export GITHUB_OUTPUT="$TEST_STATE/output" GITHUB_STEP_SUMMARY="$TEST_STATE/summary"
  export READ_SEQUENCE="$TAG_TARGET_SHA"
  mkdir "$TEST_STATE/bin"
  export PATH="$TEST_STATE/bin:$PATH"
  cat >"$TEST_STATE/bin/gh" <<'SH'
#!/bin/bash
[ "$1" = api ] || exit 97
shift
case "$1" in
  repos/example/project/git/ref/heads/main)
    n=$(cat "$TEST_STATE/count" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" >"$TEST_STATE/count"
    echo read >>"$TEST_STATE/events"
    value=$(printf '%s\n' "$READ_SEQUENCE" | sed -n "${n}p")
    [ -n "$value" ] || value=$(printf '%s\n' "$READ_SEQUENCE" | tail -1)
    case "$value" in
      error) echo 'raw transport error' >&2; exit 1 ;;
      malformed) response='{"object":{"type":"tag","sha":"bad"}}' ;;
      numeric) response='{"object":{"type":"commit","sha":2222222222222222222222222222222222222222}}' ;;
      empty) response='{"object":{"type":"commit","sha":""}}' ;;
      *) response=$(jq -nc --arg sha "$value" '{object:{type:"commit",sha:$sha}}') ;;
    esac
    # Honor gh's real --jq behavior; production jq validation remains real.
    if [ "${2:-}" = --jq ]; then
      printf '%s\n' "$response" | jq -r "$3"
    else
      printf '%s\n' "$response"
    fi
    ;;
  -X)
    [ "$*" = "-X POST repos/example/project/git/refs -f ref=refs/tags/v1.2.4 -f sha=$TAG_TARGET_SHA" ] || exit 97
    echo post >>"$TEST_STATE/events"
    ;;
  repos/example/project/git/commits/*) echo true ;;
  *) exit 97 ;;
esac
SH
  cat >"$TEST_STATE/bin/sleep" <<'SH'
#!/bin/sh
echo "sleep $*" >>"$TEST_STATE/events"
SH
  chmod +x "$TEST_STATE/bin/gh" "$TEST_STATE/bin/sleep"
  awk '
    $0 == "      - name: Create and push tag" { step=1; next }
    step && /^      - / { exit }
    step && /^        run: \|$/ { body=1; next }
    body { sub(/^          /, ""); print }
  ' "$YAML" >"$TEST_STATE/step.sh"
}

run_step() { run bash -e "$TEST_STATE/step.sh"; }

assert_no_tag() {
  [ "$status" -ne 0 ]
  ! grep -q post "$TEST_STATE/events"
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "immediate target creates the exact tag without sleeping" {
  run_step
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_STATE/events")" = $'read\npost' ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'tag=v1.2.4' ]
}

@test "pre-bump source then target waits before creating the tag" {
  export READ_SEQUENCE="$PLANNED_SOURCE_SHA
$TAG_TARGET_SHA"
  run_step
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_STATE/events")" = $'read\nsleep 2\nread\npost' ]
  [[ "$output" == *"observed $PLANNED_SOURCE_SHA"* ]]
  [[ "$output" == *"expected $TAG_TARGET_SHA"* ]]
}

@test "persistent pre-bump source exhausts the bounded wait without tagging" {
  export READ_SEQUENCE="$PLANNED_SOURCE_SHA"
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/count")" -eq 6 ]
  [ "$(grep -c '^sleep' "$TEST_STATE/events")" -eq 5 ]
  [[ "$output" == *"expected $TAG_TARGET_SHA"* ]]
  [[ "$output" == *"observed $PLANNED_SOURCE_SHA"* ]]
}

@test "unrelated movement fails immediately without tagging" {
  export READ_SEQUENCE=3333333333333333333333333333333333333333
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = read ]
  [[ "$output" == *"observed $READ_SEQUENCE"* ]]
}

@test "movement after an old-source read stops polling without tagging" {
  export READ_SEQUENCE="$PLANNED_SOURCE_SHA
3333333333333333333333333333333333333333
$TAG_TARGET_SHA"
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = $'read\nsleep 2\nread' ]
}

@test "no-bump target succeeds without polling" {
  export TAG_TARGET_SHA="$PLANNED_SOURCE_SHA" READ_SEQUENCE="$PLANNED_SOURCE_SHA"
  run_step
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_STATE/events")" = $'read\npost' ]
}

@test "no-bump mismatch fails immediately" {
  export TAG_TARGET_SHA="$PLANNED_SOURCE_SHA"
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = read ]
}

@test "API failure fails closed without retrying or exposing raw errors" {
  export READ_SEQUENCE=error
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = read ]
  [[ "$output" != *"raw transport error"* ]]
}

@test "malformed ref fails closed without polling" {
  export READ_SEQUENCE=malformed
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = read ]
  [[ "$output" == *"malformed"* ]]
}

@test "empty commit SHA fails closed without polling" {
  export READ_SEQUENCE=empty
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = read ]
  [[ "$output" == *"malformed"* ]]
}

@test "numeric SHA cannot authorize tag creation" {
  export READ_SEQUENCE=numeric
  run_step
  assert_no_tag
  [ "$(cat "$TEST_STATE/events")" = read ]
  [[ "$output" == *"malformed"* ]]
}
