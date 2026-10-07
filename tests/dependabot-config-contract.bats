#!/usr/bin/env bats

@test "GitHub Actions updater covers root and composite actions, with minor and patch grouped" {
  local config="$BATS_TEST_DIRNAME/../.github/dependabot.yml" actions group
  # Values are compared as compact JSON: yq's own == is neither deep nor type-strict.
  actions='[.updates[] | select(.["package-ecosystem"] == "github-actions" and (.directories | to_json(0)) == "[\"/\",\"/actions/*\"]")]'

  # expected exactly one root GitHub Actions updater
  [ "$(yq "$actions | length" "$config")" = 1 ]
  # directory and directories are mutually exclusive
  [ "$(yq "$actions | .[0] | has(\"directory\")" "$config")" = false ]
  # expected all-actions to be the only GitHub Actions group
  [ "$(yq -o=json -I=0 "$actions | .[0].groups // {} | keys" "$config")" = '["all-actions"]' ]

  group="$actions | .[0].groups[\"all-actions\"]"
  [ "$(yq -o=json -I=0 "$group | .[\"applies-to\"]" "$config")" = '"version-updates"' ]
  [ "$(yq -o=json -I=0 "$group | .patterns" "$config")" = '["*"]' ]
  [ "$(yq -o=json -I=0 "$group | .[\"update-types\"] // [] | sort" "$config")" = '["minor","patch"]' ]
}
