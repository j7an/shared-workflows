#!/usr/bin/env bash
# assert-packed-manifest.sh — verify a packed tarball is safe to publish.
#
# Reads package/package.json out of the SEALED tarball rather than the working
# tree, and checks two things:
#
#   1. Identity. The sealed name and version must match what the workflow was
#      asked to publish. Preflight already checked the on-disk manifest, but
#      prepack/prepare lifecycle scripts run between then and now and may
#      rewrite it. npm versions are immutable, so publishing the wrong package
#      cannot be undone - only superseded.
#
#   2. Dependency protocol class. Rejection works by allowlist: the accepted
#      set is npm's non-local resolution protocols - the registry, the git-host
#      shortcuts and remote tarballs - verified against npm's own
#      npm-package-arg parser, while the rejected set is package-manager
#      workspace sugar that grows over time. A newly invented protocol
#      therefore fails loudly here instead of publishing silently.
#
# `private` is deliberately NOT re-checked here even though a prepack script
# could set it after preflight rejected it: `npm publish` refuses a private
# package outright, so that path already fails closed one job later.
#
# SCOPE OF THE SECOND CHECK. It matches a protocol PREFIX. It does not
# validate the rest of the specifier, so a malformed value carrying an allowed
# prefix passes - 'npm:', 'npm:@scope' and 'https:' all throw in
# npm-package-arg but pass here. The promise is therefore narrow: this guard
# rejects local-path and workspace-protocol dependency classes. It does not
# certify that a surviving specifier resolves. Malformed specifiers of that
# kind break the publisher's own install long before reaching this point; the
# failure this guard exists to prevent is a WELL-FORMED workspace: specifier
# that packs and publishes green.
#
# Usage:
#   ./scripts/assert-packed-manifest.sh <tarball-path> <expected-name> <expected-version>
#
# Exit codes:
#   0 — identity confirmed and no disallowed specifier
#   1 — identity mismatch, or one or more disallowed specifiers (all listed)
#   2 — the tarball is unreadable or has no package/package.json

set -euo pipefail

tarball="${1-}"
expected_name="${2-}"
expected_version="${3-}"

if [ -z "$expected_name" ] || [ -z "$expected_version" ]; then
  echo "::error::usage: assert-packed-manifest.sh <tarball-path> <expected-name> <expected-version>" >&2
  exit 2
fi
if [ -z "$tarball" ] || [ ! -f "$tarball" ]; then
  echo "::error::assert-packed-manifest.sh: tarball '${tarball}' not found" >&2
  exit 2
fi

manifest=$(tar -xzOf "$tarball" package/package.json 2>/dev/null || true)
if [ -z "$manifest" ]; then
  echo "::error::${tarball} contains no package/package.json" >&2
  exit 2
fi
if ! printf '%s' "$manifest" | jq -e . >/dev/null 2>&1; then
  echo "::error::${tarball} package/package.json is not valid JSON" >&2
  exit 2
fi

# --- identity ------------------------------------------------------------
sealed_name=$(printf '%s' "$manifest" | jq -r '.name // ""')
sealed_version=$(printf '%s' "$manifest" | jq -r '.version // ""')

if [ "$sealed_name" != "$expected_name" ]; then
  echo "::error::Sealed manifest name '${sealed_name}' does not match the requested package '${expected_name}'. A prepack or prepare script may have rewritten package.json after preflight - refusing to publish" >&2
  exit 1
fi
if [ "$sealed_version" != "$expected_version" ]; then
  echo "::error::Sealed manifest version '${sealed_version}' does not match the requested version '${expected_version}' - refusing to publish" >&2
  exit 1
fi

# --- dependency protocol class -------------------------------------------
# field <TAB> name <TAB> specifier, for the three fields a consumer installs.
# devDependencies are deliberately absent: they are never installed from a
# published package, so a workspace: there is harmless.
rows=$(printf '%s' "$manifest" | jq -r '
  ["dependencies","optionalDependencies","peerDependencies"][] as $f
  | (.[$f] // {}) | to_entries[]
  | [$f, .key, (.value | tostring)] | @tsv
')

violations=0
tab=$(printf '\t')

while IFS="$tab" read -r field name spec; do
  if [ -z "$field" ]; then
    continue
  fi

  # Trim literal whitespace and only leading jq @tsv tab/newline/CR escapes.
  # This preserves field framing and keeps any later escape sequence inside a
  # single diagnostic line. A literal '\\t' or '\\n' from the manifest arrives
  # doubled and does not match these one-backslash patterns.
  while :; do
    spec="${spec#"${spec%%[![:space:]]*}"}"
    case "$spec" in
      \\t*) spec="${spec#\\t}" ;;
      \\n*) spec="${spec#\\n}" ;;
      \\r*) spec="${spec#\\r}" ;;
      *) break ;;
    esac
  done

  # Anchored at the start so 'github:u/r#semver:^1.0.0' yields 'github:',
  # never 'semver:'. Plain ranges, tags and '*' carry no colon at all.
  proto=$(printf '%s' "$spec" \
    | grep -oiE '^[a-z][a-z0-9+.-]*:' \
    | tr '[:upper:]' '[:lower:]' || true)
  if [ -z "$proto" ]; then
    # npm-package-arg resolves a leading '.', '/' or '~/' to a local directory
    # with no protocol prefix, so '../core' means exactly 'file:../core'.
    # The 'C:' Windows-drive form npa also accepts is already caught above as
    # an unknown protocol. The tilde is backslash-escaped because a case
    # pattern is tilde-expanded: a bare ~/* would match $HOME, not '~/'.
    case "$spec" in
      .*|/*|\~/*) proto="file:" ;;
      *) continue ;;
    esac
  fi

  case "$proto" in
    npm:|git:|git+ssh:|git+http:|git+https:|http:|https:|github:|gitlab:|bitbucket:|gist:)
      continue ;;
  esac

  violations=$((violations + 1))
  case "$proto" in
    workspace:)
      hint='set pack-command to "pnpm pack --json" and complete a frozen install before packing' ;;
    catalog:)
      hint='set pack-command to "pnpm pack --json" so pnpm resolves the catalog entry' ;;
    link:|portal:|patch:|file:|git+file:)
      hint='a local path cannot be published; depend on a registry version instead' ;;
    *)
      hint='unrecognized dependency protocol; if it is registry-resolvable, please open an issue' ;;
  esac
  printf '::error::%s.%s uses unpublishable specifier %s - %s\n' \
    "$field" "$name" "$spec" "$hint" >&2
done <<EOF
$rows
EOF

if [ "$violations" -gt 0 ]; then
  echo "::error::${tarball} sealed ${violations} unpublishable dependency specifier(s)" >&2
  exit 1
fi

echo "${tarball} is ${sealed_name}@${sealed_version} with no unpublishable dependency specifiers."
