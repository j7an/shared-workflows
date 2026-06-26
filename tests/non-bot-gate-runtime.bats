#!/usr/bin/env bats
# non-bot-gate-runtime.bats - execute the reusable non-bot gate run block
# against a stubbed gh CLI. The trusted pull_request_target path must fail
# loud on every gh error; it has no 403 soft-fail path.

YAML=".github/workflows/dependency-safety-non-bot-gate.yml"

setup() {
  TEST_TMP=$(mktemp -d)
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  export GH_REPO="octo/example"
  export HEAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="octo/example"
  export GITHUB_RUN_ID="123"
}

teardown() {
  rm -rf "$TEST_TMP"
}

extract_gate_block() {
  awk '
    /^      - name: Post dependency-safety gate status$/ { in_step = 1 }
    in_step && /^        run: \|$/ { in_run = 1; next }
    in_run && /^      - name: / { exit }
    in_run { print }
  ' "$YAML" | sed -E 's/^          //'
}

write_gh_stub() {
  printf '%s' "$1" > "$TEST_TMP/gh_msg"
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TEST_TMP/gh_args"
cat "$TEST_TMP/gh_msg" >&2
if [ -s "$TEST_TMP/gh_msg" ]; then
  echo >&2
fi
exit $2
EOF
  chmod +x "$STUB_BIN/gh"
}

run_gate_block() {
  local f="$TEST_TMP/gate.sh"
  { echo 'set -eo pipefail'; extract_gate_block; } > "$f"
  PATH="$STUB_BIN:$PATH" run bash "$f"
}

@test "status post succeeds with populated HEAD_SHA" {
  write_gh_stub "" 0
  run_gate_block
  [ "$status" -eq 0 ]
  grep -qx "api" "$TEST_TMP/gh_args"
  grep -qx "repos/octo/example/statuses/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$TEST_TMP/gh_args"
  grep -qx "state=success" "$TEST_TMP/gh_args"
  grep -qx "context=dependency-safety / gate" "$TEST_TMP/gh_args"
  grep -qx "description=Non-bot PR: dependency-safety scan not required" "$TEST_TMP/gh_args"
  grep -qx "target_url=https://github.com/octo/example/actions/runs/123" "$TEST_TMP/gh_args"
}

@test "empty HEAD_SHA fails before calling gh" {
  export HEAD_SHA=""
  write_gh_stub "" 0
  run_gate_block
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::dependency-safety non-bot gate requires a pull_request_target caller"* ]]
  [ ! -s "$TEST_TMP/gh_args" ]
}

@test "403 from gh fails loud" {
  write_gh_stub '{"message":"Resource not accessible by integration","status":"403","documentation_url":"https://docs.github.com/rest"}' 1
  run_gate_block
  [ "$status" -ne 0 ]
  [[ "$output" == *"Resource not accessible by integration"* ]]
}

@test "generic gh failure fails loud" {
  write_gh_stub "gh: HTTP 500 Internal Server Error" 1
  run_gate_block
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 500"* ]]
}
