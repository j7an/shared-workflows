#!/usr/bin/env bats

@test "GitHub Actions minor and patch version updates are grouped together" {
  config="$BATS_TEST_DIRNAME/../.github/dependabot.yml"

  run ruby - "$config" <<'RUBY'
require "yaml"

config = YAML.safe_load(File.read(ARGV.fetch(0)))
updates = config.fetch("updates")
actions = updates.select do |update|
  update["package-ecosystem"] == "github-actions" && update["directory"] == "/"
end

abort "expected exactly one root GitHub Actions updater" unless actions.length == 1

groups = actions.first.fetch("groups", {})
abort "expected all-actions to be the only GitHub Actions group" unless groups.keys == ["all-actions"]

group = groups.fetch("all-actions")
abort "all-actions must apply only to version updates" unless group["applies-to"] == "version-updates"
abort "all-actions must match every action" unless group["patterns"] == ["*"]
abort "all-actions must group only minor and patch updates" unless group.fetch("update-types", []).sort == %w[minor patch]
RUBY

  [ "$status" -eq 0 ]
}
