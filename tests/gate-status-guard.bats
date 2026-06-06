#!/usr/bin/env bats
# gate-status-guard.bats — runtime tests for the `Set initial status` gate
# step's NON-BOT status write (issue #79). The non-bot success POST must:
#   - stay green + emit a notice when the status write is denied by a
#     read-only token (HTTP 403 "Resource not accessible by integration"),
#     i.e. the external-fork-PR case;
#   - still fail loudly on any OTHER gh error;
#   - behave unchanged (skip=true, no notice) when the write succeeds.
#
# The bot/pending branch and the final status write are intentionally NOT
# guarded and are not exercised here.

YAML=".github/workflows/dependency-safety.yml"

setup() {
  TEST_TMP=$(mktemp -d)
  STUB_BIN="$TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  export GITHUB_OUTPUT="$TEST_TMP/out"
  export GITHUB_STEP_SUMMARY="$TEST_TMP/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  # Env the gate block reads (normally supplied by the step's `env:` map).
  export GH_REPO="octo/example"
  export HEAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="octo/example"
  export GITHUB_RUN_ID="123"
  # Non-bot author → exercises the guarded branch.
  export PR_AUTHOR="alice"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# Extract the `Set initial status` step's run-block body as plain bash.
extract_gate_block() {
  awk '
    /^      - name: Set initial status$/ { in_step = 1 }
    in_step && /^        run: \|$/        { in_run = 1; next }
    in_run && /^      - name: /           { exit }
    in_run                                { print }
  ' "$YAML" | sed -E 's/^          //'
}

# Write a fake `gh` that prints $1 to stderr and exits $2. The message is
# stored in a file the stub reads at runtime, so quoting in the message — e.g.
# the JSON 403 body {"message":"...","status":"403"} — cannot corrupt the
# generated stub script.
write_gh_stub() {
  printf '%s' "$1" > "$TEST_TMP/gh_msg"
  cat > "$STUB_BIN/gh" <<EOF
#!/usr/bin/env bash
cat "$TEST_TMP/gh_msg" >&2
echo >&2
exit $2
EOF
  chmod +x "$STUB_BIN/gh"
}

# Run the extracted gate block under a GHA-equivalent shell with the stub on PATH.
run_gate_block() {
  local f="$TEST_TMP/gate.sh"
  { echo 'set -eo pipefail'; extract_gate_block; } > "$f"
  PATH="$STUB_BIN:$PATH" run bash "$f"
}

@test "non-bot fork PR: read-only 403 → notice, green job, skip=true" {
  write_gh_stub "gh: Resource not accessible by integration (HTTP 403)" 1
  run_gate_block
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  grep -q "skip=true" "$GITHUB_OUTPUT"
  grep -q "cannot post the 'dependency-safety / gate' commit status" "$GITHUB_STEP_SUMMARY"
}

@test "non-bot fork PR: JSON 403 body → notice, green job, skip=true" {
  write_gh_stub '{"message":"Resource not accessible by integration","status":"403","documentation_url":"https://docs.github.com/rest"}' 1
  run_gate_block
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  grep -q "skip=true" "$GITHUB_OUTPUT"
  grep -q "cannot post the 'dependency-safety / gate' commit status" "$GITHUB_STEP_SUMMARY"
}

@test "non-bot PR: unrelated gh error still fails loudly" {
  write_gh_stub "gh: HTTP 500 Internal Server Error" 1
  run_gate_block
  [ "$status" -ne 0 ]
  ! grep -q "skip=true" "$GITHUB_OUTPUT"
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "non-bot same-repo PR: status write succeeds → skip=true, no notice" {
  write_gh_stub "" 0
  run_gate_block
  [ "$status" -eq 0 ]
  grep -q "skip=true" "$GITHUB_OUTPUT"
  [[ "$output" != *"::notice::"* ]]
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}
