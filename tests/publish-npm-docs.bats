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
