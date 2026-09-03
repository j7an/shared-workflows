#!/usr/bin/env bash

set -euo pipefail

die_input() {
  printf '::error::revalidate tag-release plan: %s\n' "$1" >&2
  exit 2
}

die_state() {
  printf '::error::revalidate tag-release plan: %s\n' "$1" >&2
  exit 1
}

require_value() {
  eval "value=\${$1-}"
  [ -n "$value" ] || die_input "$1 is required"
}

is_sha1() {
  printf '%s' "$1" | grep -qE '^[0-9a-f]{40}$'
}

tag_snapshot_sha256() {
  git for-each-ref \
    --format='%(refname)%09%(objectname)' \
    "refs/tags/${TAG_PREFIX}*.*.*" |
    LC_ALL=C sort |
    shasum -a 256 |
    awk '{print $1}'
}

for name in \
  GITHUB_REPOSITORY GH_TOKEN TAG_PREFIX PLANNED_SOURCE_SHA \
  PLANNED_FIRST_RELEASE PLANNED_TAG_SNAPSHOT_SHA256 PLANNED_NEXT_TAG; do
  require_value "$name"
done

printf '%s' "$GITHUB_REPOSITORY" |
  grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ||
  die_input "GITHUB_REPOSITORY must be owner/repo"
printf '%s' "$TAG_PREFIX" | grep -qE '^[A-Za-z0-9._/-]+$' ||
  die_input "TAG_PREFIX has an invalid shape"
is_sha1 "$PLANNED_SOURCE_SHA" ||
  die_input "PLANNED_SOURCE_SHA is not a lowercase 40-character SHA"
printf '%s' "$PLANNED_TAG_SNAPSHOT_SHA256" |
  grep -qE '^[0-9a-f]{64}$' ||
  die_input "PLANNED_TAG_SNAPSHOT_SHA256 is not a lowercase SHA-256"

case "$PLANNED_FIRST_RELEASE" in
  true|false) ;;
  *) die_input "PLANNED_FIRST_RELEASE must be true or false" ;;
esac

version=${PLANNED_NEXT_TAG#"$TAG_PREFIX"}
[ "$version" != "$PLANNED_NEXT_TAG" ] &&
  printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  die_input "PLANNED_NEXT_TAG is not the selected prefix plus stable SemVer"

if [ "$PLANNED_FIRST_RELEASE" = true ]; then
  [ -z "${PLANNED_LATEST_TAG-}" ] ||
    die_input "PLANNED_LATEST_TAG must be empty for a first release"
  [ -z "${PLANNED_LATEST_REF_SHA-}" ] ||
    die_input "PLANNED_LATEST_REF_SHA must be empty for a first release"
  [ -z "${PLANNED_LATEST_COMMIT_SHA-}" ] ||
    die_input "PLANNED_LATEST_COMMIT_SHA must be empty for a first release"
else
  require_value PLANNED_LATEST_TAG
  require_value PLANNED_LATEST_REF_SHA
  require_value PLANNED_LATEST_COMMIT_SHA
  is_sha1 "$PLANNED_LATEST_REF_SHA" ||
    die_input "PLANNED_LATEST_REF_SHA is not a lowercase 40-character SHA"
  is_sha1 "$PLANNED_LATEST_COMMIT_SHA" ||
    die_input "PLANNED_LATEST_COMMIT_SHA is not a lowercase 40-character SHA"
fi

head_sha=$(git rev-parse HEAD 2>/dev/null) ||
  die_state "could not inspect checked-out source"
[ "$head_sha" = "$PLANNED_SOURCE_SHA" ] ||
  die_state "checked-out source does not match the approved source"

if ! main_json=$(gh api \
  "repos/${GITHUB_REPOSITORY}/git/ref/heads/main" 2>/dev/null); then
  die_state "could not inspect live main"
fi
if ! live_main=$(printf '%s\n' "$main_json" |
  jq -er 'select(.object.type == "commit") | .object.sha |
    select(type == "string")' 2>/dev/null); then
  die_state "live main response was malformed"
fi
is_sha1 "$live_main" || die_state "live main response was malformed"
[ "$live_main" = "$PLANNED_SOURCE_SHA" ] ||
  die_state "main changed after release planning"

if ! current_latest=$(git tag -l "${TAG_PREFIX}*.*.*" \
  --sort=-version:refname 2>/dev/null | sed -n '1p'); then
  die_state "could not inspect matching tags"
fi
if [ -z "$current_latest" ]; then
  current_first_release=true
  current_ref_sha=
  current_commit_sha=
else
  current_first_release=false
  current_ref_sha=$(git rev-parse "refs/tags/$current_latest" 2>/dev/null) ||
    die_state "could not inspect latest tag ref"
  current_commit_sha=$(git rev-parse "$current_latest^{commit}" 2>/dev/null) ||
    die_state "could not inspect latest tag target"
fi

[ "$current_first_release" = "$PLANNED_FIRST_RELEASE" ] ||
  die_state "first-release state changed"
[ "$current_latest" = "${PLANNED_LATEST_TAG-}" ] ||
  die_state "highest matching tag changed"
[ "$current_ref_sha" = "${PLANNED_LATEST_REF_SHA-}" ] ||
  die_state "latest tag ref changed"
[ "$current_commit_sha" = "${PLANNED_LATEST_COMMIT_SHA-}" ] ||
  die_state "latest tag target changed"

if ! current_digest=$(tag_snapshot_sha256 2>/dev/null); then
  die_state "could not inspect matching tag set"
fi
[ "$current_digest" = "$PLANNED_TAG_SNAPSHOT_SHA256" ] ||
  die_state "matching tag set changed"

if ! matches_json=$(gh api \
  "repos/${GITHUB_REPOSITORY}/git/matching-refs/tags/${PLANNED_NEXT_TAG}" \
  2>/dev/null); then
  die_state "could not inspect proposed tag"
fi
if ! exact_count=$(printf '%s\n' "$matches_json" |
  jq -er --arg ref "refs/tags/$PLANNED_NEXT_TAG" \
    'if type == "array" and
        all(.[];
          (.ref | type == "string") and
          (.object | type == "object") and
          (.object.type == "commit" or .object.type == "tag") and
          ((.object.sha | type) == "string") and
          (.object.sha | test("^[0-9a-f]{40}$")))
     then
       [.[] | select(.ref == $ref)] | length
     else error("not an array")
     end' 2>/dev/null); then
  die_state "proposed-tag response was malformed"
fi
[ "$exact_count" -eq 0 ] || die_state "proposed tag already exists"

printf 'revalidate tag-release plan: approved release plan is still current\n' >&2
