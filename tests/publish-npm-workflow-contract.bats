#!/usr/bin/env bats
# publish-npm-workflow-contract.bats - static contract checks for publish-npm.yml

YAML=".github/workflows/publish-npm.yml"

workflow_inputs_block() {
  sed -n '/^  workflow_call:$/,/^permissions:$/p' "$YAML"
}

build_job() {
  sed -n '/^  build:$/,/^  publish:$/p' "$YAML"
}

publish_job() {
  sed -n '/^  publish:$/,/^  github-release:$/p' "$YAML"
}

github_release_job() {
  sed -n '/^  github-release:$/,$p' "$YAML"
}

input_block() {
  local input="$1"
  workflow_inputs_block | sed -n "/^      ${input}:$/,/^      [a-zA-Z0-9_-]*:$/p"
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

run_blocks() {
  awk '
    /^        run: \|$/ { in_run=1; next }
    /^        run: / { sub(/^        run: /, ""); print; next }
    in_run && /^      - / { in_run=0; next }
    in_run && /^    [A-Za-z0-9_-]+:/ { in_run=0; next }
    in_run { print }
  ' "$YAML"
}

@test "publish-npm.yml is workflow_call only with generic inputs" {
  grep -q '^  workflow_call:$' "$YAML"
  ! grep -qE '^  (push|pull_request|workflow_dispatch|schedule):' "$YAML"

  inputs="$(workflow_inputs_block)"
  assert_contains "$inputs" "tag:"
  assert_contains "$inputs" "package-name:"
  assert_contains "$inputs" "test-command:"
  assert_contains "$inputs" "pack-contents-script:"
  assert_contains "$inputs" "verify-command:"
}

@test "optional caller hooks default to empty strings" {
  assert_contains "$(input_block test-command)" 'default: ""'
  assert_contains "$(input_block pack-contents-script)" 'default: ""'
  assert_contains "$(input_block verify-command)" 'default: ""'
}

@test "publish-npm.yml serializes releases by tag" {
  grep -q '^concurrency:$' "$YAML"
  grep -qF 'group: publish-npm-${{ inputs.tag }}' "$YAML"
  grep -qF 'cancel-in-progress: false' "$YAML"
}

@test "build job checks out full tag history and verifies it is on main" {
  job="$(build_job)"
  assert_contains "$job" 'ref: ${{ inputs.tag }}'
  assert_contains "$job" 'fetch-depth: 0'
  assert_contains "$job" 'persist-credentials: false'
  assert_lacks "$job" 'git fetch origin main'
  assert_contains "$job" 'merge-base --is-ancestor'
}

@test "build job gates tag version against package.json version" {
  job="$(build_job)"
  assert_contains "$job" "require('./package.json').version"
  assert_contains "$job" 'refusing to publish'
  assert_contains "$job" 'version=$VERSION'
}

@test "build job uses Node 24 and optional caller pre-pack hooks" {
  job="$(build_job)"
  assert_contains "$job" 'node-version: "24"'
  assert_contains "$job" 'TEST_COMMAND: ${{ inputs.test-command }}'
  assert_contains "$job" 'if [ -n "$TEST_COMMAND" ]; then'
  assert_contains "$job" 'PACK_CONTENTS_SCRIPT: ${{ inputs.pack-contents-script }}'
  assert_contains "$job" 'sh "$PACK_CONTENTS_SCRIPT" pack.json'
}

@test "build job packs once and uploads npm-dist tarball artifact" {
  job="$(build_job)"
  assert_contains "$job" 'npm pack --json > pack.json'
  assert_contains "$job" "name: npm-dist"
  assert_contains "$job" 'path: "*.tgz"'
  assert_contains "$job" 'if-no-files-found: error'
}

@test "publish job declares OIDC permission and npm environment" {
  job="$(publish_job)"
  assert_contains "$job" 'environment: npm'
  assert_contains "$job" 'id-token: write'
}

@test "publish job uses Node 24 and enforces npm trusted-publishing floor" {
  job="$(publish_job)"
  assert_contains "$job" 'node-version: "24"'
  assert_contains "$job" '24.0.0'
  assert_contains "$job" '11.5.1'
}

@test "publish job publishes the downloaded tarball without explicit provenance config" {
  job="$(publish_job)"
  assert_contains "$job" 'name: npm-dist'
  assert_contains "$job" 'if npm view "${PACKAGE}@${VERSION}" version >/dev/null 2>&1; then'
  assert_contains "$job" 'already exists on npm; skipping npm publish.'
  assert_contains "$job" 'npm publish ./*.tgz'
  ! grep -qE -- '--provenance|NPM_CONFIG_PROVENANCE' "$YAML"
}

@test "publish job verifies registry visibility and optional caller verify-command" {
  job="$(publish_job)"
  assert_contains "$job" 'Attempt 1/6: checking registry before sleep...'
  assert_contains "$job" 'npm view "${PACKAGE}@${VERSION}" version'
  assert_contains "$job" 'VERIFY_COMMAND: ${{ inputs.verify-command }}'
  assert_contains "$job" 'if [ -n "$VERIFY_COMMAND" ]; then'
  assert_contains "$job" 'sh -c "$VERIFY_COMMAND"'
}

@test "GitHub Release job attaches the verified tarball and handles existing releases" {
  job="$(github_release_job)"
  assert_contains "$job" 'needs: [build, publish]'
  assert_contains "$job" 'contents: write'
  assert_contains "$job" 'name: npm-dist'
  assert_contains "$job" 'persist-credentials: false'
  assert_contains "$job" 'gh release upload "$TAG" ./*.tgz --clobber'
  assert_contains "$job" 'ARGS+=( ./*.tgz )'
  assert_contains "$job" '--generate-notes'
  assert_contains "$job" '--verify-tag'
}

@test "GitHub Release prerelease classification uses parsed version, not full tag" {
  job="$(github_release_job)"
  assert_contains "$job" 'VERSION: ${{ needs.build.outputs.version }}'
  assert_contains "$job" '[[ "$VERSION" == *-* ]]'
  assert_lacks "$job" '[[ "$TAG" == *-* ]]'
}

@test "inputs reach shell run blocks through env indirection" {
  runs="$(run_blocks)"
  assert_contains "$runs" 'npm publish ./*.tgz'
  assert_lacks "$runs" '${{ inputs.'
}
