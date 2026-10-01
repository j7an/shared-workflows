#!/usr/bin/env bats

load helpers/action-pin-assertions

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "version inputs are exact and tracked" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
ALLOWLIST = { 'node-version' => 'floats within a major on purpose' }
entries = matrix_entries
each_with_block do |file, uses, inputs|
  inputs.each do |key, value|
    next unless key == 'version' || key.end_with?('-version')
    next if ALLOWLIST.key?(key)
    abort "#{file}: #{key} must be an exact version string" unless value.is_a?(String) && value.match?(/\A\d+\.\d+\.\d+\z/)
    abort "#{file}: #{key} is not tracked by the updater" unless entries.any? { |entry| entry['key'] == key && entry['files'].include?(file) }
  end
end
RUBY
  [ "$status" -eq 0 ]
}

@test "tool-installing actions set their version" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
REQUIRED = { 'zizmorcore/zizmor-action' => 'version', 'astral-sh/setup-uv' => 'version', 'bats-core/bats-action' => 'bats-version' }
each_with_block do |file, uses, inputs|
  REQUIRED.each do |action, key|
    next unless uses.to_s.start_with?("#{action}@")
    abort "#{file}: #{action} must set #{key}" unless inputs.key?(key)
  end
end
RUBY
  [ "$status" -eq 0 ]
}

@test "matrix entries match a pin in every file" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
matrix_entries.each do |entry|
  entry['files'].each do |file|
    abort "#{file}: no exact #{entry['key']} pin" unless File.read(file).match?(PIN_LINE.(entry['key']))
  end
end
RUBY
  [ "$status" -eq 0 ]
}

@test "minimum age equals Dependabot cooldown" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
file = '.github/workflows/tool-pin-bump.yml'
workflow = YAML.safe_load(File.read(file))
updates = YAML.safe_load(File.read('.github/dependabot.yml'))['updates']
actions = updates.find { |update| update['package-ecosystem'] == 'github-actions' }
abort "#{file}: minimum age differs from Dependabot cooldown" unless workflow.dig('env', 'MIN_AGE_DAYS') == actions.dig('cooldown', 'default-days')
RUBY
  [ "$status" -eq 0 ]
}

@test "workflow permissions are minimal" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
file = '.github/workflows/tool-pin-bump.yml'
workflow = YAML.safe_load(File.read(file))
job = workflow['jobs']['bump']
abort "#{file}: top-level permissions must deny all" unless workflow['permissions'] == {}
abort "#{file}: job permissions must only read contents" unless job['permissions'] == { 'contents' => 'read' }
token = job['steps'].find { |step| step['id'] == 'app-token' }
abort "#{file}: App token must allow workflow updates" unless token.dig('with', 'permission-workflows') == 'write'
RUBY
  [ "$status" -eq 0 ]
}

@test "bump step fails on API errors" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
file = '.github/workflows/tool-pin-bump.yml'
workflow = YAML.safe_load(File.read(file))
bump = workflow['jobs']['bump']['steps'].find { |step| step['id'] == 'bump' }
abort "#{file}: bump must use explicit bash for pipefail" unless bump['shell'] == 'bash'
RUBY
  [ "$status" -eq 0 ]
}

@test "PR branch is fixed per tool" {
  run ruby -r ./tests/helpers/tool-pins.rb - <<'RUBY'
file = '.github/workflows/tool-pin-bump.yml'
workflow = YAML.safe_load(File.read(file))
pr = workflow['jobs']['bump']['steps'].find { |step| step['uses'].to_s.start_with?('peter-evans/create-pull-request@') }['with']
abort "#{file}: PR branch must be fixed per tool" unless pr['branch'] == 'deps/tool-pin-${{ matrix.name }}'
abort "#{file}: PR commits must be signed" unless pr['sign-commits'] == true
abort "#{file}: PR branch must be cleaned up" unless pr['delete-branch'] == true
token = pr['token'].to_s
abort "#{file}: PR must use only the App token" unless token.include?('steps.app-token.outputs.token') && !token.include?('github.token')
RUBY
  [ "$status" -eq 0 ]
}

@test "actions are SHA-pinned" {
  local workflow
  workflow=$(cat .github/workflows/tool-pin-bump.yml)
  assert_action_pin "$workflow" "step-security/harden-runner"
  assert_action_pin "$workflow" "actions/checkout"
  assert_action_pin "$workflow" "actions/create-github-app-token"
  assert_action_pin "$workflow" "peter-evans/create-pull-request"
}


prepare_bump_step() {
  local root="$PWD"
  export API_FIXTURES="$BATS_TEST_TMPDIR/api"
  mkdir -p "$API_FIXTURES" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/scripts"
  cp scripts/bump-tool-pin.sh "$BATS_TEST_TMPDIR/scripts/"
  ruby -r yaml -e 'puts YAML.safe_load(File.read(ARGV[0])).dig("jobs", "bump", "steps").find { |s| s["id"] == "bump" }["run"]' .github/workflows/tool-pin-bump.yml > "$BATS_TEST_TMPDIR/bump.sh"
  export OLD_REF NEW_REF
  OLD_REF=$(printf '%040d' 1)
  NEW_REF=$(printf '%040d' 2)
  local file
  for file in security-scan security; do
    sed -E "s#(zizmorcore/zizmor-action@)[0-9a-f]+#\1$OLD_REF#; s@version: \"[0-9]+[.][0-9]+[.][0-9]+\"@version: \"1.0.0\"@" "$root/.github/workflows/$file.yml" > "$BATS_TEST_TMPDIR/$file.yml"
  done
  printf 'latest digest\n2.0.0 digest\n' > "$API_FIXTURES/$OLD_REF"
  printf 'latest digest\n2.0.0 digest\n3.0.0 digest\n' > "$API_FIXTURES/$NEW_REF"
  cat > "$API_FIXTURES/releases" <<'JSON'
[{"tag_name":"v3.0.0","published_at":"2020-01-01T00:00:00Z"},{"tag_name":"2.0.0","published_at":"2020-01-01T00:00:00Z"}]
JSON
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$API_FIXTURES/calls"
case "$*" in
  *'/releases?per_page=100') cat "$API_FIXTURES/releases" ;;
  *'Accept: application/vnd.github.raw+json'*'/contents/support/versions?ref='*)
    ref=${*: -1}
    cat "$API_FIXTURES/${ref##*ref=}" ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" REPO=zizmorcore/zizmor KEY=version MIN_AGE_DAYS=5
  export FILES='security-scan.yml security.yml' GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : > "$GITHUB_OUTPUT"
  cd "$BATS_TEST_TMPDIR"
}

@test "zizmor excludes aged releases unsupported by the pinned action" {
  prepare_bump_step
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  rg -q '^new=2.0.0$' "$GITHUB_OUTPUT"
  rg -q 'version: "2.0.0"' security-scan.yml
  rg -q 'version: "2.0.0"' security.yml
}

@test "updating zizmor action refs admits newly supported releases" {
  prepare_bump_step
  sed "s/$OLD_REF/$NEW_REF/" security.yml > updated.yml
  cp updated.yml security.yml
  cp security.yml security-scan.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  rg -q '^new=3.0.0$' "$GITHUB_OUTPUT"
}

@test "different zizmor action refs intersect supported releases" {
  prepare_bump_step
  sed "s/$OLD_REF/$NEW_REF/" security.yml > updated.yml
  cp updated.yml security.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  rg -q '^new=2.0.0$' "$GITHUB_OUTPUT"
  rg -q "support/versions[?]ref=$OLD_REF" "$API_FIXTURES/calls"
  rg -q "support/versions[?]ref=$NEW_REF" "$API_FIXTURES/calls"
}

@test "zizmor support fetch failure precedes edits and outputs" {
  prepare_bump_step
  rm "$API_FIXTURES/$OLD_REF"
  cp security-scan.yml before-scan.yml
  cp security.yml before.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -ne 0 ]
  cmp security.yml before.yml
  cmp security-scan.yml before-scan.yml
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "zizmor rejects unpinned action refs before fetching support" {
  prepare_bump_step
  sed "s/$OLD_REF/main/" security.yml > updated.yml
  cp updated.yml security.yml
  cp security.yml before.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -ne 0 ]
  cmp security.yml before.yml
  [ ! -s "$GITHUB_OUTPUT" ]
  ! rg -q 'support/versions' "$API_FIXTURES/calls"
}

@test "non-zizmor release selection is unaffected by action support" {
  prepare_bump_step
  export REPO=astral-sh/uv
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  rg -q '^new=3.0.0$' "$GITHUB_OUTPUT"
  ! rg -q 'support/versions' "$API_FIXTURES/calls"
}

@test "README documents intentional tool floats and their controls" {
  run ruby - <<'RUBY'
text = File.read('.github/workflows/README.md').split(/^### Intentional floats\s*$/, 2)[1]
abort 'missing intentional floats note' unless text
text = text.split(/^## /, 2)[0]
[/Node.*major/i, /Trivy.*action.*default/i, /diff-cover.*range/i, /diff-cover.*lower.bound/i, /pnpm.*integrity/i].each do |pattern|
  abort "missing float policy: #{pattern}" unless text.match?(pattern)
end
RUBY
  [ "$status" -eq 0 ]
}
