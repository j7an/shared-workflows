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
