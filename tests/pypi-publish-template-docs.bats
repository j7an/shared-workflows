#!/usr/bin/env bats
# pypi-publish-template-docs.bats - contracts for the caller-owned PyPI template.

template_yaml() {
  awk '
    /^### Standard release workflow$/ { section=1; next }
    section && /^```yaml[[:space:]]*$/ { code=1; next }
    code && /^[[:space:]]*```[[:space:]]*$/ { exit }
    code { print }
  ' .github/workflows/README.md
}

template_job() {
  template_yaml | awk -v key="  $1:" '
    $0 == key { found=1; print; next }
    found && /^  [a-zA-Z0-9_-]+:$/ { exit }
    found { print }
  '
}

@test "template gates production publication on successful verification" {
  local edge job dependency block
  for edge in publish-testpypi:build verify-testpypi:publish-testpypi \
    publish-pypi:verify-testpypi github-release:publish-pypi; do
    job=${edge%%:*}; dependency=${edge#*:}
    block=$(template_job "$job")
    printf '%s\n' "$block" | grep -qx "    needs: $dependency" || {
      printf 'missing template dependency: %s\n' "$edge" >&2; return 1;
    }
  done
}

@test "template grants OIDC only to publishing jobs" {
  local job block root_permissions
  root_permissions=$(template_yaml | awk '
    /^permissions:$/ { found=1; next }
    found && /^[^[:space:]]/ { exit }
    found { print }
  ')
  printf '%s\n' "$root_permissions" | grep -qx '  contents: read' || return 1
  if printf '%s\n' "$root_permissions" | grep -q 'id-token:'; then return 1; fi
  for job in publish-testpypi publish-pypi; do
    block=$(template_job "$job")
    printf '%s\n' "$block" | grep -qx '      id-token: write' || return 1
    printf '%s\n' "$block" | grep -qx '    environment:' || return 1
  done
  for job in build verify-testpypi github-release; do
    block=$(template_job "$job")
    [ -n "$block" ] || return 1
    if printf '%s\n' "$block" | grep -q 'id-token:'; then return 1; fi
  done
}

@test "template verification preserves command and index boundaries" {
  local block expected body python_guard package_guard toml_write
  block=$(template_job verify-testpypi)
  for expected in \
    'VERIFY_COMMAND: ${{ env.VERIFY_COMMAND }}' \
    'VERIFY_PYTHON: ${{ env.VERIFY_PYTHON }}' \
    'PACKAGE_NAME: ${{ env.PACKAGE_NAME }}' \
    'cat > .verify/pyproject.toml' \
    '[tool.uv.sources]' \
    '"${PACKAGE_NAME}" = { index = "testpypi" }' \
    'url = "https://test.pypi.org/simple/"' \
    'explicit = true' \
    'uv sync --python "$VERIFY_PYTHON" --refresh-package "$PACKAGE_NAME"' \
    'uv run --no-sync bash -euo pipefail -c "$VERIFY_COMMAND"'; do
    [[ "$block" == *"$expected"* ]] || {
      printf 'missing template safeguard: %s\n' "$expected" >&2; return 1;
    }
  done
  [[ "$block" != *'uv pip install'* ]] || return 1
  [[ "$block" != *'--extra-index-url'* ]] || return 1
  body=$(printf '%s\n' "$block" | sed -n '/^        run: |$/,$p')
  [[ "$body" != *'${{ env.VERIFY_COMMAND }}'* ]] || return 1
  python_guard=$(printf '%s\n' "$body" | grep -nF "grep -qE '^[0-9]+(\\.[0-9]+){1,2}$'" | cut -d: -f1)
  package_guard=$(printf '%s\n' "$body" | grep -nF "grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'" | cut -d: -f1)
  toml_write=$(printf '%s\n' "$body" | grep -nF 'cat > .verify/pyproject.toml' | cut -d: -f1)
  [ -n "$python_guard" ] && [ -n "$package_guard" ] && [ -n "$toml_write" ] || return 1
  [ "$python_guard" -lt "$toml_write" ] && [ "$package_guard" -lt "$toml_write" ] || return 1
}

@test "template production publishing does not skip existing artifacts" {
  local block
  block=$(template_job publish-pypi)
  [ -n "$block" ] || return 1
  [[ "$block" == *'packages-dir: dist/'* ]] || return 1
  if printf '%s\n' "$block" | grep -qE 'skip-existing:[[:space:]]*true'; then
    return 1
  fi
}
