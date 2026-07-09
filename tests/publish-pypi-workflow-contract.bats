#!/usr/bin/env bats
# publish-pypi-workflow-contract.bats - static checks for publish-pypi.yml

YAML=".github/workflows/publish-pypi.yml"

workflow_inputs_block() {
  sed -n '/^  workflow_call:$/,/^permissions:$/p' "$YAML"
}

input_block() {
  local input="$1"
  workflow_inputs_block | sed -n "/^      ${input}:$/,/^      [a-zA-Z0-9_-]*:$/p"
}

verify_step() {
  awk '
    /^      - name: Verify install from TestPyPI$/ { flag=1; next }
    flag && /^  publish-pypi:$/ { exit }
    flag { print }
  ' "$YAML"
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]]
}

assert_lacks() {
  local text="$1"
  local forbidden="$2"
  [[ "$text" != *"$forbidden"* ]]
}

@test "publish-pypi.yml exposes explicit verify-python input with Python 3.13 default" {
  block="$(input_block verify-python)"
  assert_contains "$block" 'type: string'
  assert_contains "$block" 'default: "3.13"'
  assert_contains "$block" 'Python version used for TestPyPI install verification'
}

@test "TestPyPI verification validates interpreter and package before TOML interpolation" {
  step="$(verify_step)"
  assert_contains "$step" 'VERIFY_PYTHON: ${{ inputs.verify-python }}'
  assert_contains "$step" "grep -qE '^[0-9]+(\\.[0-9]+){1,2}$'"
  assert_contains "$step" "grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'"
}

@test "TestPyPI verification writes an ephemeral project with source pinning" {
  step="$(verify_step)"
  assert_contains "$step" 'rm -rf .verify'
  assert_contains "$step" 'cat > .verify/pyproject.toml'
  assert_contains "$step" 'requires-python = ">='
  assert_contains "$step" 'dependencies = ['
  assert_contains "$step" '[tool.uv.sources]'
  assert_contains "$step" '"${TESTPYPI_PACKAGE}" = { index = "testpypi" }'
  assert_contains "$step" '[[tool.uv.index]]'
  assert_contains "$step" 'url = "https://test.pypi.org/simple/"'
  assert_contains "$step" 'explicit = true'
}

@test "TestPyPI verification syncs with configured Python and refreshes the package under test" {
  step="$(verify_step)"
  assert_contains "$step" 'uv sync --python "$VERIFY_PYTHON" --refresh-package "$TESTPYPI_PACKAGE"'
}

@test "TestPyPI verification parses normalized PEP 440 tag tails" {
  step="$(verify_step)"
  assert_contains "$step" "[0-9]+\\.[0-9]+\\.[0-9]+([A-Za-z][A-Za-z0-9.]*)?$"
  assert_contains "$step" "1.2.3rc1"
  assert_lacks "$step" "-[A-Za-z0-9.]"
}

@test "TestPyPI verification does not use uv pip multi-index install" {
  step="$(verify_step)"
  assert_lacks "$step" 'uv pip install'
  assert_lacks "$step" '--index-url https://test.pypi.org/simple/'
  assert_lacks "$step" '--extra-index-url https://pypi.org/simple/'
}
