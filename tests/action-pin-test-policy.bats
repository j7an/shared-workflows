#!/usr/bin/env bats
# action-pin-test-policy.bats - semantic helper and source-policy contracts for
# workflow action-pin tests.

. "$BATS_TEST_DIRNAME/helpers/action-pin-assertions.bash"

@test "action pin helper accepts Dependabot SHA and version bumps" {
  sha=$(printf '%040d' 1)
  block=$(printf '%s\n%s\n' \
    '      - name: Perform CodeQL analysis' \
    "        uses: github/codeql-action/analyze@$sha # v4.99.0")

  assert_action_pin "$block" "github/codeql-action/analyze"
}

@test "action pin helper rejects malformed pins" {
  sha=$(printf '%040d' 1)

  block='        uses: github/codeql-action/analyze@v4.99.0 # v4.99.0'
  if assert_action_pin "$block" "github/codeql-action/analyze"; then
    echo "expected non-SHA action ref to fail"
    return 1
  fi

  block="        uses: github/codeql-action/analyze@$sha # v4"
  if assert_action_pin "$block" "github/codeql-action/analyze"; then
    echo "expected malformed version comment to fail"
    return 1
  fi

  block="        uses: github/codeql-action/analyze@$sha"
  if assert_action_pin "$block" "github/codeql-action/analyze"; then
    echo "expected missing version comment to fail"
    return 1
  fi
}

@test "action pin helper requires an exact dotted target match" {
  sha=$(printf '%040d' 1)
  block="    uses: google/osv-scanner-action/Xgithub/workflows/osv-scanner-reusableXyml@$sha # v2.99.0"

  if assert_action_pin "$block" "google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml"; then
    echo "expected exact dotted target match"
    return 1
  fi
}

@test "action pin helper requires exactly one matching reference" {
  first_sha=$(printf '%040d' 1)
  second_sha=$(printf '%040d' 2)
  block=$(printf '%s\n%s\n' \
    "        uses: actions/checkout@$first_sha # v7.0.0" \
    "        uses: actions/checkout@$second_sha # v7.1.0")

  if assert_action_pin "$block" "actions/checkout"; then
    echo "expected duplicate action references to fail"
    return 1
  fi
}

find_literal_action_pin_snapshots() {
  awk '
    /[[:alnum:]_.-]+\/[[:alnum:]_.\/-]+@[0-9A-Fa-f]{40}[[:space:]]+#[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+([^0-9.]|$)/ {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
  ' "$@"
}

@test "literal action-pin detector reports source path and line" {
  source_file="$BATS_TEST_TMPDIR/literal-action-pin.bats"
  sha=$(printf '%040d' 1)
  line="assert_contains \"\$block\" \"actions/checkout@$sha # v7.0.0\""
  printf '%s\n' "$line" >"$source_file"

  run find_literal_action_pin_snapshots "$source_file"

  [ "$status" -eq 0 ]
  [ "$output" = "$source_file:1:$line" ]
}

@test "literal action-pin detector requires the complete triple" {
  source_file="$BATS_TEST_TMPDIR/non-literal-action-pins.bats"
  sha=$(printf '%040d' 2)
  head_sha=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  printf '%s\n' \
    "HEAD_SHA=$head_sha" \
    "uses: actions/checkout@$sha" \
    "uses: actions/checkout@v7 # v7.0.0" \
    'assert_action_pin "$block" "actions/checkout"' \
    >"$source_file"

  run find_literal_action_pin_snapshots "$source_file"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "workflow contract tests do not snapshot literal action pins" {
  violations=$(find_literal_action_pin_snapshots "$BATS_TEST_DIRNAME"/*.bats)
  if [ -n "$violations" ]; then
    printf 'literal action-pin snapshots found:\n%s\n' "$violations"
    return 1
  fi
}
