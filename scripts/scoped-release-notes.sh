#!/usr/bin/env bash
# scoped-release-notes.sh — GitHub Release notes for publish-npm.yml limited to
# the pull requests that touched the caller's `paths`.
#
# GitHub's generated notes list every PR merged between two tags across the
# whole repo, and with no explicit base they start from the newest release in
# ANY tag stream. In a monorepo with per-package tags (permissions/v0.3.0,
# rewind/v0.1.0) both are wrong. This script picks the base from the tag's own
# prefix stream, asks GitHub for notes over that range, and keeps only the PR
# lines whose number appears in `git log <base>..<tag> -- <paths>`.
#
# The base is the nearest lower version in the stream; a stable release skips
# prereleases so its notes cover everything since the previous stable release.
# With no base (first release in the stream) the API cannot be given a range,
# so the notes say so and link the tag's history instead.
#
# ponytail: PR numbers come from the trailing "(#N)" GitHub puts on squash-merge
# subjects. Merge-commit or rebase-merge callers need a per-commit
# `repos/{repo}/commits/{sha}/pulls` lookup instead.
#
# Usage (inside a checkout with full history and tags):
#   ./scripts/scoped-release-notes.sh <tag> <path>...
#
# Env: GITHUB_REPOSITORY (owner/name), GITHUB_SERVER_URL (default
# https://github.com), and GH_TOKEN for gh.
#
# Stdout: the release notes body (Markdown).
#
# Exit codes:
#   0 — notes written, including the no-match and first-release bodies
#   1 — <tag> is not a local tag, or the GitHub API call failed
#   2 — malformed input: missing arguments or GITHUB_REPOSITORY, an
#       unparseable tag, or a paths entry outside [A-Za-z0-9._/-]

set -euo pipefail

tag="${1-}"
if [ -z "$tag" ] || [ "$#" -lt 2 ] || [ -z "${GITHUB_REPOSITORY-}" ]; then
  echo "::error::usage: GITHUB_REPOSITORY=owner/name scoped-release-notes.sh <tag> <path>..." >&2
  exit 2
fi
shift

# Same charset as tag-release.yml's paths, so git pathspec magic (':!x') and
# globs are rejected. [[ =~ ]] matches the whole string, newlines included.
path_re='^[A-Za-z0-9._/-]+$'
for p in "$@"; do
  if ! [[ "$p" =~ $path_re ]]; then
    echo "::error::Invalid paths entry '$p' (must match [A-Za-z0-9._/-]+)" >&2
    exit 2
  fi
done

if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "::error::Tag '${tag}' does not exist in this checkout" >&2
  exit 1
fi

# Same trailing-semver anchor as npm-package-preflight.sh; what precedes it is
# the stream's prefix (e.g. "permissions/v").
version=$(printf '%s' "$tag" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$' || true)
if [ -z "$version" ]; then
  echo "::error::Could not parse semver version from tag '${tag}'" >&2
  exit 2
fi
prefix="${tag%"$version"}"
case "$version" in
  *-*) skip_pre=0 ;;
  *) skip_pre=1 ;;
esac

# versionsort.suffix=- sorts 1.0.0-rc.1 below 1.0.0. The awk keeps only tags
# that are exactly <prefix><semver>, so prefix "v" ignores "vendor/v1.5.0".
base=$(git -c versionsort.suffix=- tag -l "${prefix}*" --sort=-version:refname \
  | awk -v p="$prefix" -v t="$tag" -v skip_pre="$skip_pre" '
      substr($0, 1, length(p)) != p { next }
      { v = substr($0, length(p) + 1) }
      v !~ /^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$/ { next }
      seen && !found && !(skip_pre && v ~ /-/) { print; found = 1 }
      $0 == t { seen = 1 }
    ')

server="${GITHUB_SERVER_URL:-https://github.com}"
if [ -z "$base" ]; then
  echo "::notice::No earlier ${prefix}* tag before ${tag}; writing first-release notes" >&2
  printf 'First release in the `%s` stream.\n\n**Full Changelog**: %s/%s/commits/%s\n' \
    "$prefix" "$server" "$GITHUB_REPOSITORY" "$tag"
  exit 0
fi

notes=$(gh api -X POST "repos/${GITHUB_REPOSITORY}/releases/generate-notes" \
  -f tag_name="$tag" -f previous_tag_name="$base" --jq .body)

prs=$(git log --format=%s "${base}..${tag}" -- "$@" \
  | sed -nE 's/.*\(#([0-9]+)\)$/\1/p' | tr '\n' ' ')

# Keep PR bullets in the set. A heading is held until a kept bullet follows,
# so sections emptied by the filter (e.g. "## New Contributors") disappear.
printf '%s\n' "$notes" | awk -v prs=" ${prs} " -v paths="$*" '
  /^#/ { held = $0 "\n"; next }
  /^\* .*\/pull\/[0-9]+$/ {
    n = $0
    sub(/.*\/pull\//, "", n)
    if (index(prs, " " n " ")) { out = out held $0 "\n"; held = ""; kept++ }
    next
  }
  held != "" && /^$/ { held = held "\n"; next }
  /^\*\*Full Changelog\*\*/ { changelog = $0 }
  { held = ""; out = out $0 "\n" }
  END {
    if (kept) { printf "%s", out; exit }
    printf "## What\047s Changed\n* No pull requests in this release touched `%s`.\n", paths
    if (changelog != "") printf "\n%s\n", changelog
  }
'
