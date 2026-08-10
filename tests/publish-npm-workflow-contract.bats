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

step_line() {
  grep -n "^      - name: $1\$" "$YAML" | head -n1 | cut -d: -f1
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

@test "build job preflights the selected package before tests or packing" {
  job="$(build_job)"
  assert_contains "$job" 'PACKAGE_DIR: ${{ inputs.package-dir }}'
  assert_contains "$job" 'PACKAGE_NAME: ${{ inputs.package-name }}'
  assert_contains "$job" 'npm_package_preflight "$PACKAGE_DIR" "$PACKAGE_NAME" "$TAG"'
  assert_contains "$job" 'refusing to publish'
  assert_lacks "$job" "require('./package.json').version"
  assert_contains "$job" 'cat "$OUT" >> "$GITHUB_OUTPUT"'
  assert_contains "$job" 'version: ${{ steps.pkg.outputs.version }}'
}

@test "build job uses Node 24 and optional caller pre-pack hooks" {
  job="$(build_job)"
  assert_contains "$job" 'node-version: "24"'
  assert_contains "$job" 'TEST_COMMAND: ${{ inputs.test-command }}'
  assert_contains "$job" 'if [ -n "$TEST_COMMAND" ]; then'
  assert_contains "$job" 'PACK_CONTENTS_SCRIPT: ${{ inputs.pack-contents-script }}'
  assert_contains "$job" 'sh "$PACK_CONTENTS_SCRIPT" "$PACK_JSON_REL"'
}

@test "build job packs once from the selected directory and stages the tarball" {
  job="$(build_job)"
  assert_contains "$job" 'PACKAGE_DIR: ${{ steps.pkg.outputs.dir }}'
  assert_contains "$job" 'PACK_COMMAND: ${{ inputs.pack-command }}'
  assert_contains "$job" 'PACK_JSON="$RUNNER_TEMP/pack.json"'
  assert_contains "$job" 'STAGE="$RUNNER_TEMP/dist"'
  assert_contains "$job" 'Expected exactly one tarball'
  assert_contains "$job" "name: npm-dist"
  assert_contains "$job" 'path: ${{ runner.temp }}/dist/*.tgz'
  assert_contains "$job" 'if-no-files-found: error'
  assert_lacks "$job" 'npm pack --json > pack.json'
  assert_lacks "$job" 'path: "*.tgz"'
}

@test "the pack command is invoked exactly once" {
  count=$(grep -oF 'sh -c "$PACK_COMMAND"' "$YAML" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

@test "the guard is invoked exactly once" {
  count=$(grep -oF 'assert_packed_manifest "$RUNNER_TEMP/dist"' "$YAML" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}

@test "the guard receives the requested name and version" {
  job="$(build_job)"
  assert_contains "$job" 'PACKAGE_NAME: ${{ inputs.package-name }}'
  assert_contains "$job" 'VERSION: ${{ steps.pkg.outputs.version }}'
  assert_contains "$job" 'assert_packed_manifest "$RUNNER_TEMP/dist"/*.tgz "$PACKAGE_NAME" "$VERSION"'
}

@test "pack metadata is written outside the workspace" {
  job="$(build_job)"
  assert_contains "$job" 'PACK_JSON="$RUNNER_TEMP/pack.json"'
  assert_lacks "$job" '> pack.json'
}

@test "the staged tarball is bound to the pack metadata filename" {
  job="$(build_job)"
  assert_contains "$job" 'EXPECTED_TARBALL'
  assert_contains "$job" 'if [ "$FOUND_BASE" != "$EXPECTED_TARBALL" ]; then'
  assert_contains "$job" 'refusing to publish a stale tarball'
  # The echo alone would not stop the publish; the refusal must exit non-zero.
  printf '%s\n' "$job" \
    | grep -A1 'refusing to publish a stale tarball' \
    | grep -qE '^[[:space:]]*exit 1$'
}

@test "corepack enables only pnpm and yarn, never the npm shim" {
  job="$(build_job)"
  assert_contains "$job" 'corepack enable pnpm yarn'
  # Bare `corepack enable`, `--all`, and any explicit `npm` argument all install
  # the npm shim, which hard-errors in a repo pinning packageManager: pnpm@...
  # Only real command lines are considered, so the explanatory comment above the
  # command (which names npm in prose) cannot satisfy or defeat this check.
  ! printf '%s\n' "$job" \
    | grep -E '^[[:space:]]*corepack enable' \
    | grep -qE '(enable[[:space:]]*$|[[:space:]]npm([[:space:]]|$)|--all)' || return 1
}

@test "pack failures surface the packer's real error keys" {
  job="$(build_job)"
  # npm's envelope is {"error":{"code","summary","detail"}} - there is no
  # "message" key, so pinning it alone would certify a dead branch.
  assert_contains "$job" '[.error.summary, .error.detail, .error.message]'
  assert_lacks "$job" '.error.message // empty'
  assert_lacks "$job" '.error.message // "unknown"'
  assert_contains "$job" 'has("error")'
  # Safety net: unrecognized envelopes are dumped, never swallowed.
  assert_contains "$job" 'sed '"'"'s/^/::error::/'"'"' "$PACK_JSON"'
}

@test "the packed manifest is asserted before upload" {
  asrt="$(step_line 'Assert packed manifest is the requested package')"
  upld="$(step_line 'Upload tarball artifact')"
  [ -n "$asrt" ]
  [ -n "$upld" ]
  [ "$asrt" -lt "$upld" ]
  grep -qF '# --- BEGIN inline:scripts/assert-packed-manifest.sh ---' "$YAML"
  grep -qF '# --- END inline:scripts/assert-packed-manifest.sh ---' "$YAML"
}

@test "publish and github-release jobs stay artifact-driven" {
  pub="$(publish_job)"
  rel="$(github_release_job)"
  assert_contains "$pub" 'npm publish ./*.tgz'
  assert_contains "$rel" 'gh release upload "$TAG" ./*.tgz --clobber'
  assert_lacks "$pub" 'package-dir'
  assert_lacks "$rel" 'package-dir'
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

@test "publish-npm.yml exposes package-dir and pack-command with safe defaults" {
  inputs="$(workflow_inputs_block)"
  assert_contains "$inputs" "package-dir:"
  assert_contains "$inputs" "pack-command:"
  assert_contains "$(input_block package-dir)" 'default: "."'
  assert_contains "$(input_block pack-command)" 'default: "npm pack --json"'
}

@test "preflight runs before the caller test command" {
  pre="$(step_line 'Resolve package directory and preflight')"
  tst="$(step_line 'Run caller test command')"
  pck="$(step_line 'Pack once and stage the tarball')"
  [ -n "$pre" ]
  [ -n "$tst" ]
  [ -n "$pck" ]
  [ "$pre" -lt "$tst" ]
  [ "$pre" -lt "$pck" ]
}

@test "preflight logic is embedded inline, not fetched at runtime" {
  grep -qF '# --- BEGIN inline:scripts/npm-package-preflight.sh ---' "$YAML"
  grep -qF '# --- END inline:scripts/npm-package-preflight.sh ---' "$YAML"
}

@test "preflight is invoked exactly once" {
  count=$(grep -oF 'npm_package_preflight "$PACKAGE_DIR"' "$YAML" | wc -l | tr -d ' ')
  [ "$count" -eq 1 ]
}
