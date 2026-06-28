#!/usr/bin/env bats
# pypi-publish-template-docs.bats - lint-grade checks for PyPI publish docs.

README=".github/workflows/README.md"

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

publish_pypi_section() {
  awk '
    /^## `publish-pypi.yml`$/ { flag=1; print; next }
    flag && /^## / { exit }
    flag { print }
  ' "$README"
}

template_section() {
  awk '
    /^## Caller-owned PyPI Trusted Publishing template$/ { flag=1; print; next }
    flag && /^## / { exit }
    flag { print }
  ' "$README"
}

normalize_text() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]*> ?//' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g'
}

@test "publish-pypi.yml docs no longer advertise impossible Trusted Publishing setup" {
  section=$(normalize_text "$(publish_pypi_section)")
  assert_contains "$section" "not supported for PyPI/TestPyPI Trusted Publishing"
  assert_contains "$section" "Current PyPI behavior"
  assert_contains "$section" "cross-repo reusable workflows as Trusted Publisher"
  assert_contains "$section" "Long-lived API-token publishing is intentionally out of scope"
  assert_lacks "$section" 'workflow `j7an/shared-workflows/.github/workflows/publish-pypi.yml`'
  assert_lacks "$section" 'GitHub Environments `testpypi` and `pypi` exist in `j7an/shared-workflows`'
}

@test "caller-owned template documents required local trusted-publisher setup" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" 'Create GitHub Environments `testpypi` and `pypi` in the package repo'
  assert_contains "$section" "Configure PyPI Trusted Publisher"
  assert_contains "$section" "Configure TestPyPI Trusted Publisher"
  assert_contains "$section" "workflow path of the caller-owned release workflow"
}

@test "caller-owned template includes the safe release job graph" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" "build:"
  assert_contains "$section" "publish-testpypi:"
  assert_contains "$section" "verify-testpypi:"
  assert_contains "$section" "publish-pypi:"
  assert_contains "$section" "github-release:"
  assert_contains "$section" "needs: publish-testpypi"
  assert_contains "$section" "needs: verify-testpypi"
  assert_contains "$section" "needs: publish-pypi"
  assert_lacks "$section" "needs.build.outputs"
}

@test "verification job is documented as no-OIDC and command-safe" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" "permissions:"
  assert_contains "$section" "contents: read"
  assert_contains "$section" 'VERIFY_COMMAND: example-pkg --version'
  assert_contains "$section" 'bash -euo pipefail -c "$VERIFY_COMMAND"'
  assert_contains "$section" 'must never be interpolated directly into `run:`'
}

@test "template uses first-party gh release and not softprops" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" "gh release create"
  assert_contains "$section" "scripts/classify-prerelease.sh"
  assert_lacks "$section" "softprops/action-gh-release"
  assert_lacks "$section" '[[ "$TAG" == *-* ]]'
}

@test "template documents TestPyPI skip-existing as opt-in and keeps production strict" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" 'Set TestPyPI `skip-existing: true` only when rerun ergonomics are worth'
  assert_contains "$section" "freshness tradeoff"
  assert_contains "$section" 'Do not set `skip-existing`'
  assert_contains "$section" "production PyPI publish step"
}

@test "template documents normalized prerelease tag spelling" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" "Use normalized tag tails"
  assert_contains "$section" '`v1.2.3rc1`'
  assert_contains "$section" 'Do not tag prereleases as `v1.2.3-rc1`'
}

@test "template documents trigger adjustment for path-prefixed tags" {
  section=$(normalize_text "$(template_section)")
  assert_contains "$section" "path-prefixed (for example"
  assert_contains "$section" "standard trigger"
  assert_contains "$section" "tools/v*.*.*"
  assert_contains "$section" "add the matching trigger pattern"
}
