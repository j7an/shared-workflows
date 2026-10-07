#!/usr/bin/env bats
# scoped-release-notes.bats — publish-npm.yml's paths-scoped release notes.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  SCRIPT="$REPO_ROOT/scripts/scoped-release-notes.sh"
  TEST_REPO="$BATS_TEST_TMPDIR/repo"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  GH_ARGS="$BATS_TEST_TMPDIR/gh-args"
  mkdir -p "$TEST_REPO" "$FAKE_BIN"

  git -C "$TEST_REPO" init -q
  git -C "$TEST_REPO" config user.name "Release Notes Test"
  git -C "$TEST_REPO" config user.email "notes@example.invalid"
  git -C "$TEST_REPO" config commit.gpgSign false
  git -C "$TEST_REPO" config tag.gpgSign false

  export PATH="$FAKE_BIN:$PATH"
  export GITHUB_REPOSITORY="example/project"
  export GITHUB_SERVER_URL="https://github.com"
  export GH_ARGS
  export FAKE_NOTES_FILE="$BATS_TEST_TMPDIR/notes.md"

  # Stub: records its argv and prints the canned generate-notes body.
  cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$GH_ARGS"
case "$*" in
  *releases/generate-notes*) cat "$FAKE_NOTES_FILE" ;;
  *) exit 97 ;;
esac
SH
  chmod +x "$FAKE_BIN/gh"
}

# commit <subject> <path>... — touch each path and commit.
commit() {
  local subject="$1"
  shift
  local p
  for p in "$@"; do
    mkdir -p "$TEST_REPO/$(dirname "$p")"
    printf '%s\n' "$subject" >>"$TEST_REPO/$p"
    git -C "$TEST_REPO" add "$p"
  done
  git -C "$TEST_REPO" commit -qm "$subject"
}

tag() {
  git -C "$TEST_REPO" tag "$1"
}

run_script() {
  run --separate-stderr bash -c 'cd "$1" && shift && "$@"' _ "$TEST_REPO" "$SCRIPT" "$@"
}

# Mirrors pi-kit permissions/v0.2.0..permissions/v0.3.0 (issue #179): only #24
# touched packages/permissions or packages/shared, and a newer tag in another
# stream (rewind/v0.1.0) exists.
pi_kit_history() {
  commit "feat(permissions): first (#10)" packages/permissions/index.ts
  tag permissions/v0.2.0
  commit "feat(rewind): add file and conversation rewind (#21)" packages/rewind/index.ts
  commit "deps: bump @types/node (#22)" pnpm-lock.yaml
  commit "feat(shared): add @pi-kit/shared (#24)" packages/shared/index.ts packages/permissions/index.ts
  commit "chore(release): bump version files to 0.3.0" packages/permissions/package.json
  tag permissions/v0.3.0
  commit "feat(rewind): polish (#26)" packages/rewind/index.ts
  tag rewind/v0.1.0
}

@test "keeps only PRs that touched the paths and drops emptied sections" {
  pi_kit_history
  cat >"$FAKE_NOTES_FILE" <<'MD'
## What's Changed
* feat(rewind): add file and conversation rewind by @j7an in https://github.com/example/project/pull/21
* deps: bump @types/node by @dependabot[bot] in https://github.com/example/project/pull/22
* feat(shared): add @pi-kit/shared by @j7an in https://github.com/example/project/pull/24

## New Contributors
* @someone made their first contribution in https://github.com/example/project/pull/22

**Full Changelog**: https://github.com/example/project/compare/permissions/v0.2.0...permissions/v0.3.0
MD

  run_script permissions/v0.3.0 packages/permissions packages/shared

  [ "$status" -eq 0 ]
  expected="## What's Changed
* feat(shared): add @pi-kit/shared by @j7an in https://github.com/example/project/pull/24

**Full Changelog**: https://github.com/example/project/compare/permissions/v0.2.0...permissions/v0.3.0"
  [ "$output" = "$expected" ]
}

@test "previous tag comes from the same prefix stream, not the newest release" {
  pi_kit_history
  printf '%s\n' '**Full Changelog**: x' >"$FAKE_NOTES_FILE"

  run_script permissions/v0.3.0 packages/permissions

  [ "$status" -eq 0 ]
  grep -qx 'tag_name=permissions/v0.3.0' "$GH_ARGS"
  grep -qx 'previous_tag_name=permissions/v0.2.0' "$GH_ARGS"
}

@test "says so explicitly when no PR touched the paths" {
  pi_kit_history
  cat >"$FAKE_NOTES_FILE" <<'MD'
## What's Changed
* feat(rewind): add file and conversation rewind by @j7an in https://github.com/example/project/pull/21


**Full Changelog**: https://github.com/example/project/compare/permissions/v0.2.0...permissions/v0.3.0
MD

  run_script permissions/v0.3.0 packages/nothing-here

  [ "$status" -eq 0 ]
  expected="## What's Changed
* No pull requests in this release touched \`packages/nothing-here\`.

**Full Changelog**: https://github.com/example/project/compare/permissions/v0.2.0...permissions/v0.3.0"
  [ "$output" = "$expected" ]
}

@test "first release in a stream skips generated notes and links the history" {
  commit "feat(permissions): first (#10)" packages/permissions/index.ts
  tag permissions/v0.3.0
  commit "feat(shared): first (#11)" packages/shared/index.ts
  tag shared/v0.1.0

  run_script shared/v0.1.0 packages/shared

  [ "$status" -eq 0 ]
  expected="First release in the \`shared/v\` stream.

**Full Changelog**: https://github.com/example/project/commits/shared/v0.1.0"
  [ "$output" = "$expected" ]
  [ ! -e "$GH_ARGS" ]
  [[ "$stderr" == *"::notice::"* ]]
}

@test "a stable release's base skips its own prereleases" {
  commit "feat: a (#1)" pkg/a
  tag my-pkg/v0.9.0
  commit "feat: b (#2)" pkg/b
  tag my-pkg/v1.0.0-rc.1
  commit "feat: c (#3)" pkg/c
  tag my-pkg/v1.0.0
  printf '%s\n' '**Full Changelog**: x' >"$FAKE_NOTES_FILE"

  run_script my-pkg/v1.0.0 pkg
  [ "$status" -eq 0 ]
  grep -qx 'previous_tag_name=my-pkg/v0.9.0' "$GH_ARGS"
}

@test "a prerelease's base is the release before it" {
  commit "feat: a (#1)" pkg/a
  tag my-pkg/v0.9.0
  commit "feat: b (#2)" pkg/b
  tag my-pkg/v1.0.0-rc.1
  commit "feat: c (#3)" pkg/c
  tag my-pkg/v1.0.0
  printf '%s\n' '**Full Changelog**: x' >"$FAKE_NOTES_FILE"

  run_script my-pkg/v1.0.0-rc.1 pkg
  [ "$status" -eq 0 ]
  grep -qx 'previous_tag_name=my-pkg/v0.9.0' "$GH_ARGS"
}

@test "tags that only start with the prefix are not in the stream" {
  # "v-legacy/2.0.0" matches the glob "v*" and version-sorts below
  # "v1.0.0-rc.1". A prerelease tag keeps the stable-skip rule out of the way.
  commit "feat: a (#1)" pkg/a
  tag v-legacy/2.0.0
  commit "feat: b (#2)" pkg/b
  tag v1.0.0-rc.1

  run_script v1.0.0-rc.1 pkg
  [ "$status" -eq 0 ]
  [[ "$output" == "First release in the \`v\` stream."* ]]
  [ ! -e "$GH_ARGS" ]
}

@test "rejects a paths entry outside the allowed charset" {
  pi_kit_history
  run_script permissions/v0.3.0 'packages/*'
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Invalid paths entry"* ]]
}

@test "rejects a call with no paths" {
  pi_kit_history
  run_script permissions/v0.3.0
  [ "$status" -eq 2 ]
}

@test "base is the nearest earlier tag in history, not in version-sort order" {
  # SemVer ranks beta10 below beta2 (alphanumeric identifiers compare
  # lexically); git's version sort ranks it above. Either way the base must be
  # an ancestor, or <base>..<tag> is empty and #2 is silently lost.
  commit "feat: a (#1)" pkg/a
  tag pkg/v1.0.0-beta1
  commit "feat: b (#2)" pkg/b
  tag pkg/v1.0.0-beta10
  commit "feat: c (#3)" pkg/c
  tag pkg/v1.0.0-beta2
  printf '%s\n' '* b in https://github.com/example/project/pull/2' >"$FAKE_NOTES_FILE"

  run_script pkg/v1.0.0-beta10 pkg
  [ "$status" -eq 0 ]
  grep -qx 'previous_tag_name=pkg/v1.0.0-beta1' "$GH_ARGS"
  [[ "$output" == *"/pull/2" ]]
}

@test "rejects a path outside the repository with exit 2" {
  pi_kit_history
  run_script permissions/v0.3.0 ../packages/permissions
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"outside"* ]]
}

# --- publish-npm.yml run blocks --------------------------------------------

WF="$BATS_TEST_DIRNAME/../.github/workflows/publish-npm.yml"

extract_step_block() {
  awk -v want="      - name: $1" '
    $0 == want { found=1; next }
    found && /^        run: \|$/ { inrun=1; next }
    inrun && /^      - / { exit }
    inrun && /^  [a-z-]+:$/ { exit }
    inrun { sub(/^          /, ""); print }
  ' "$WF"
}

run_step() {
  local script="$BATS_TEST_TMPDIR/step.sh"
  { echo 'set -e'; extract_step_block "$1"; } >"$script"
  run --separate-stderr bash -c 'cd "$1" && bash "$2"' _ "$TEST_REPO" "$script"
}

@test "build step rejects paths that leave the repository, before publish" {
  pi_kit_history
  export TAG=permissions/v0.3.0 PATHS="packages/permissions ../packages/shared"
  run_step "Validate paths input"
  [ "$status" -ne 0 ]
  [[ "$output$stderr" == *"::error::"* ]]
}

@test "build step accepts in-repo paths and whitespace-only paths" {
  pi_kit_history
  export TAG=permissions/v0.3.0
  PATHS="packages/permissions packages/shared" run_step "Validate paths input"
  [ "$status" -eq 0 ]
  PATHS="   " run_step "Validate paths input"
  [ "$status" -eq 0 ]
}

# gh stub for the release step: no existing release; record `release create`.
release_gh_stub() {
  cat >"$FAKE_BIN/gh" <<'SH'
#!/bin/sh
case "$*" in
  "release view"*) exit 1 ;;
  "release create"*) printf '%s\n' "$@" >"$GH_ARGS" ;;
  *releases/generate-notes*) cat "$FAKE_NOTES_FILE" ;;
  *) exit 97 ;;
esac
SH
  touch "$TEST_REPO/pkg-1.0.0.tgz"
  export RUNNER_TEMP="$BATS_TEST_TMPDIR" TAG=permissions/v0.3.0 VERSION=0.3.0
}

@test "release step treats whitespace-only paths as unset" {
  pi_kit_history
  release_gh_stub
  PATHS="   " run_step "Create or update GitHub Release"
  [ "$status" -eq 0 ]
  grep -qx -- '--generate-notes' "$GH_ARGS"
  ! grep -qx -- '--notes-file' "$GH_ARGS"
}

@test "release step scopes notes when paths is set" {
  pi_kit_history
  release_gh_stub
  printf '%s\n' '**Full Changelog**: x' >"$FAKE_NOTES_FILE"
  PATHS="packages/permissions" run_step "Create or update GitHub Release"
  [ "$status" -eq 0 ]
  grep -qx -- '--notes-file' "$GH_ARGS"
  ! grep -qx -- '--generate-notes' "$GH_ARGS"
}
