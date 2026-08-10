#!/usr/bin/env bats
# publish-npm-docs.bats - docs contract checks for publish-npm.yml

README=".github/workflows/README.md"

publish_npm_section() {
  awk '
    /^## `publish-npm.yml`$/ { flag=1; print; next }
    /^## `/ && flag { exit }
    flag { print }
  ' "$README"
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]]
}

normalize_ws() {
  tr '\n' ' ' | tr -s ' '
}

@test "README documents publish-npm.yml" {
  section="$(publish_npm_section)"
  assert_contains "$section" '## `publish-npm.yml`'
  assert_contains "$section" 'npm trusted publishing'
}

@test "README records npm-vs-PyPI reusable workflow distinction" {
  section="$(publish_npm_section)"
  normalized="$(printf '%s\n' "$section" | normalize_ws)"
  assert_contains "$normalized" 'npm validates the caller workflow filename'
  assert_contains "$section" 'If npm changes this validation model'
  assert_contains "$section" 'caller-owned template'
}

@test "README documents npm trusted publisher caller setup" {
  section="$(publish_npm_section)"
  assert_contains "$section" 'workflow filename in the package repo'
  assert_contains "$section" 'Environment: `npm`'
  assert_contains "$section" 'Allowed actions: `npm publish` only'
}

@test "README documents provenance caveat" {
  section="$(publish_npm_section)"
  normalized="$(printf '%s\n' "$section" | normalize_ws)"
  assert_contains "$normalized" 'public package'
  assert_contains "$normalized" 'public repository'
  assert_contains "$section" 'Do not pass `--provenance`'
}

@test "README caller example pins released shared-workflows tag line" {
  section="$(publish_npm_section)"
  assert_contains "$section" 'j7an/shared-workflows/.github/workflows/publish-npm.yml@v4'
  ! printf '%s\n' "$section" | grep -q '@main'
  ! printf '%s\n' "$section" | grep -q '@v5'
}

@test "README shows generic optional verify command, not hard-coded workflow behavior" {
  section="$(publish_npm_section)"
  assert_contains "$section" 'verify-command'
  assert_contains "$section" 'npx --yes "${PACKAGE}@${VERSION}" --version'
  assert_contains "$section" 'omit `verify-command`'
}

@test "README documents caller-owned install and build setup before npm pack" {
  section="$(publish_npm_section)"
  assert_contains "$section" 'prepare` or `prepack`'
  assert_contains "$section" 'npm ci && npm test && npm run build'
  assert_contains "$section" 'does not run `npm ci` by default'
}

@test "README documents package-dir and pack-command" {
  section="$(publish_npm_section)"
  assert_contains "$section" '`package-dir`'
  assert_contains "$section" '`pack-command`'
  assert_contains "$section" 'npm pack --json'
}

@test "README states the working directory of each caller hook" {
  section="$(publish_npm_section)"
  normalized="$(printf '%s\n' "$section" | normalize_ws)"
  assert_contains "$normalized" 'test-command` runs from the repository root'
  assert_contains "$normalized" 'repository-root-relative'
}

@test "README states what the pre-upload guard does not promise" {
  section="$(publish_npm_section)"
  normalized="$(printf '%s\n' "$section" | normalize_ws)"
  assert_contains "$normalized" 'does not certify'
}

@test "README scopes each invocation to a single package" {
  section="$(publish_npm_section)"
  normalized="$(printf '%s\n' "$section" | normalize_ws)"
  assert_contains "$normalized" 'one package per invocation'
  assert_contains "$section" 'tag-prefix'
  assert_contains "$section" 'permissions/v'
}

@test "README documents the pnpm workspace requirements" {
  section="$(publish_npm_section)"
  assert_contains "$section" 'packageManager'
  assert_contains "$section" 'pnpm pack --json'
  assert_contains "$section" 'frozen'
  assert_contains "$section" 'workspace:'
}

@test "README documents per-package trusted publisher setup" {
  section="$(publish_npm_section)"
  normalized="$(printf '%s\n' "$section" | normalize_ws)"
  assert_contains "$normalized" 'separately for every npm package'
  assert_contains "$section" 'id-token: write'
}

@test "the monorepo caller example is complete and copy-pasteable" {
  section="$(publish_npm_section)"
  assert_contains "$section" 'package-dir: packages/permissions'
  assert_contains "$section" 'pack-command: pnpm pack --json'
  # Scoped to the monorepo example itself, not the whole publish-npm section:
  # an unscoped count stays >=2 (the "Caller setup" permissions block and the
  # "Scope" prose sentence) even if this example's own permissions block is
  # deleted outright, so it would never catch a missing id-token here.
  example="$(printf '%s\n' "$section" | awk '/^### Example caller: monorepo package$/{f=1} f')"
  count=$(printf '%s\n' "$example" | grep -c 'id-token: write')
  [ "$count" -ge 1 ]
}

@test "README inputs table documents the pack-contents-script metadata path" {
  section="$(publish_npm_section)"
  row="$(printf '%s\n' "$section" | grep '^| `pack-contents-script`')"
  [ -n "$row" ]
  assert_contains "$row" '<package-dir>/pack.json'
  assert_contains "$row" 'for a root package'
  assert_contains "$row" 'after packing'
}

@test "README publish-npm prose lines stay wrapped" {
  section="$(publish_npm_section)"
  in_fence=0
  while IFS= read -r line; do
    if [[ "$line" == '```'* ]]; then
      if [ "$in_fence" -eq 0 ]; then
        in_fence=1
      else
        in_fence=0
      fi
      continue
    fi
    [ "$in_fence" -eq 1 ] && continue
    [[ "$line" == '|'* ]] && continue
    [ "${#line}" -le 88 ]
  done <<< "$section"
}
