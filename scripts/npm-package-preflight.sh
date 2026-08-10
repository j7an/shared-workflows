#!/usr/bin/env bash
# npm-package-preflight.sh — select and validate the package publish-npm.yml
# is about to publish.
#
# Resolves <package-dir> inside GITHUB_WORKSPACE, refuses anything that could
# reach outside the checkout, and verifies the selected manifest is the
# package the caller named at the version the tag names. Runs before the
# caller's test command and before packing so a misconfigured call fails
# early and cheaply.
#
# This establishes identity at the SOURCE. That guarantee does not survive
# packing, because prepack/prepare lifecycle scripts may rewrite the manifest,
# so assert-packed-manifest.sh re-establishes it against the sealed artifact.
#
# Usage:
#   ./scripts/npm-package-preflight.sh <package-dir> <package-name> <tag>
#
# Stdout (success only), shaped for appending to $GITHUB_OUTPUT:
#   dir=<repository-relative directory>
#   version=<semver parsed from the tag>
#
# Exit codes:
#   0 — package selected and validated
#   1 — the selected package is not publishable: private, name mismatch,
#       version mismatch, or an unparseable tag. Caller MUST fail.
#   2 — the package-dir input is malformed or unsafe: control characters,
#       absolute, contains '..', escapes the checkout, missing, or has no
#       readable package.json.

set -euo pipefail

raw_dir="${1-}"
expected_name="${2-}"
tag="${3-}"

if [ -z "$expected_name" ] || [ -z "$tag" ]; then
  echo "::error::usage: npm-package-preflight.sh <package-dir> <package-name> <tag>" >&2
  exit 2
fi

workspace="${GITHUB_WORKSPACE:-$PWD}"

# --- reject control characters -------------------------------------------
# 'dir=' is appended to $GITHUB_OUTPUT, whose key=value form treats a raw
# newline as a record separator: an embedded newline would inject a second
# output key and could override 'version'. Reject the whole control range
# rather than only CR/LF - none of it is legitimate in a path here.
#
# This is robustness, not containment: a caller who can set package-dir can
# already set pack-command, which is arbitrary shell. It earns its place by
# turning a silently corrupted $GITHUB_OUTPUT into a named error.
case "$raw_dir" in
  *[[:cntrl:]]*)
    echo "::error::package-dir contains a control character; only printable characters are allowed" >&2
    exit 2 ;;
esac

# --- package-dir shape ---------------------------------------------------
dir="$raw_dir"
if [ -z "$dir" ]; then
  dir="."
fi
while [ "${#dir}" -gt 1 ] && [ "${dir%/}" != "$dir" ]; do
  dir="${dir%/}"
done

case "$dir" in
  /*)
    echo "::error::package-dir '${raw_dir}' is absolute; it must be relative to the repository root" >&2
    exit 2 ;;
esac

# Reject '..' as a shape, not as an outcome: 'a/../a' is refused even though
# it would resolve back inside the checkout.
case "/$dir/" in
  */../*)
    echo "::error::package-dir '${raw_dir}' contains a '..' path segment" >&2
    exit 2 ;;
esac

# --- resolve and contain -------------------------------------------------
# 'cd && pwd -P' is the portable canonicalization: macOS realpath is BSD and
# lacks GNU long options. -P resolves symlinks, so a symlinked directory
# pointing outside the checkout is caught by the containment test below.
ws_real=$(cd "$workspace" 2>/dev/null && pwd -P) || {
  echo "::error::GITHUB_WORKSPACE '${workspace}' is not a directory" >&2
  exit 2
}
pkg_real=$(cd "$ws_real/$dir" 2>/dev/null && pwd -P) || {
  echo "::error::package-dir '${raw_dir}' does not exist in the checkout" >&2
  exit 2
}
case "$pkg_real" in
  "$ws_real") ;;
  "$ws_real"/*) ;;
  *)
    echo "::error::package-dir '${raw_dir}' resolves to '${pkg_real}', outside the checkout" >&2
    exit 2 ;;
esac

manifest="$pkg_real/package.json"
if [ ! -f "$manifest" ]; then
  echo "::error::package-dir '${raw_dir}' has no package.json" >&2
  exit 2
fi
if ! jq -e . "$manifest" >/dev/null 2>&1; then
  echo "::error::${dir}/package.json is not valid JSON" >&2
  exit 2
fi

# --- tag -> version --------------------------------------------------------
# Anchored on the trailing semver, so a tag-prefix such as "permissions/v"
# is ignored rather than needing to be configured here.
#
# This runs after every exit-2 (malformed input) check above, deliberately:
# exit 2 must always win over exit 1 when both are wrong, or a bad
# package-dir gets reported as "package not publishable" instead of
# "caller misconfigured the call".
#
# No control-character guard is needed on $tag itself: grep -oE extracts
# only the matched substring and discards everything else, and the matched
# charset [0-9A-Za-z.-] contains no '=', so no forged 'key=value' line can
# reach stdout through it. Widening the charset (e.g. to allow '+build'
# metadata) would need this guarantee re-checked.
version=$(printf '%s' "$tag" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$' || true)
if [ -z "$version" ]; then
  echo "::error::Could not parse semver version from tag '${tag}'" >&2
  exit 1
fi

# --- manifest policy -----------------------------------------------------
if [ "$(jq -r '.private // false' "$manifest")" = "true" ]; then
  echo "::error::${dir}/package.json is marked private:true and cannot be published" >&2
  exit 1
fi

actual_name=$(jq -r '.name // ""' "$manifest")
if [ "$actual_name" != "$expected_name" ]; then
  echo "::error::${dir}/package.json name '${actual_name}' does not match package-name input '${expected_name}'" >&2
  exit 1
fi

actual_version=$(jq -r '.version // ""' "$manifest")
if [ "$actual_version" != "$version" ]; then
  echo "::error::Tag version ${version} != ${dir}/package.json version ${actual_version} - refusing to publish" >&2
  exit 1
fi

printf 'dir=%s\n' "$dir"
printf 'version=%s\n' "$version"
