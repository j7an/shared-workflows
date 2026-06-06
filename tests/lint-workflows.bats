#!/usr/bin/env bats

# lint-workflows.bats — tests for scripts/lint-workflows.sh
#
# The wrapper runs actionlint in the known non-hanging mode
# (-shellcheck= -pyflakes=). Tests stub `actionlint` on PATH so no real
# actionlint is needed and there is zero hang risk; the stub records the
# arguments it was invoked with.

setup() {
  LINT="$BATS_TEST_DIRNAME/../scripts/lint-workflows.sh"
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  STUBDIR=$(mktemp -d)
  ARGS_FILE="$STUBDIR/args"
}

teardown() {
  rm -rf "$STUBDIR"
}

# Write a fake `actionlint` that records its args (one per line) and exits $1.
make_stub() {
  local exit_code="$1"
  cat > "$STUBDIR/actionlint" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGS_FILE"
exit $exit_code
EOF
  chmod +x "$STUBDIR/actionlint"
}

@test "invokes actionlint with shellcheck and pyflakes integrations disabled" {
  make_stub 0
  cd "$REPO_ROOT"
  run env PATH="$STUBDIR:$PATH" "$LINT"
  [ "$status" -eq 0 ]
  grep -qx -- '-shellcheck=' "$ARGS_FILE"
  grep -qx -- '-pyflakes=' "$ARGS_FILE"
  grep -q '\.github/workflows/' "$ARGS_FILE"
}

@test "propagates actionlint success exit 0" {
  make_stub 0
  cd "$REPO_ROOT"
  run env PATH="$STUBDIR:$PATH" "$LINT"
  [ "$status" -eq 0 ]
}

@test "propagates actionlint failure exit" {
  make_stub 1
  cd "$REPO_ROOT"
  run env PATH="$STUBDIR:$PATH" "$LINT"
  [ "$status" -eq 1 ]
}

@test "passes through an explicit workflow file path" {
  make_stub 0
  cd "$REPO_ROOT"
  run env PATH="$STUBDIR:$PATH" "$LINT" .github/workflows/security.yml
  [ "$status" -eq 0 ]
  grep -qx -- '-shellcheck=' "$ARGS_FILE"
  grep -qx -- '.github/workflows/security.yml' "$ARGS_FILE"
}

@test "rejects flag-like positional arguments (fixed flags not overrideable)" {
  make_stub 0
  cd "$REPO_ROOT"
  run env PATH="$STUBDIR:$PATH" "$LINT" -shellcheck=
  [ "$status" -eq 2 ]
  [[ "$output" =~ "file paths" ]]
  [ ! -f "$ARGS_FILE" ]
}

@test "fails clearly when actionlint is not installed" {
  cd "$REPO_ROOT"
  run env PATH="/usr/bin:/bin" "$LINT"
  [ "$status" -eq 127 ]
  [[ "$output" =~ actionlint ]]
}
