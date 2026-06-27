#!/usr/bin/env bats

SCRIPT="scripts/pre-commit-autoupdate-preflight.sh"

setup() {
  export CONFIG_PATH=".pre-commit-config.yaml"
  export PRE_COMMIT_VERSION=""
  export APP_ID=""
  export HAS_APP_PRIVATE_KEY=false
}

run_preflight() {
  run bash "$SCRIPT"
}

output_value() {
  printf '%s\n' "$output" | awk -F= -v key="$1" '
    $1 == key {
      sub(/^[^=]*=/, "");
      print;
      found=1;
      exit
    }
    END {
      if (!found) exit 1
    }
  '
}

@test "App ID absent and key absent uses GITHUB_TOKEN fallback" {
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value auth_mode)" = "github_token" ]
  [ "$(output_value use_fallback_caveat)" = "true" ]
}

@test "App ID absent and key present still uses GITHUB_TOKEN fallback" {
  export HAS_APP_PRIVATE_KEY=true
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value auth_mode)" = "github_token" ]
  [ "$(output_value use_fallback_caveat)" = "true" ]
}

@test "App ID present and key present uses App auth" {
  export APP_ID="123456"
  export HAS_APP_PRIVATE_KEY=true
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value auth_mode)" = "app" ]
  [ "$(output_value use_fallback_caveat)" = "false" ]
}

@test "App ID present and key absent fails with half-configured error" {
  export APP_ID="123456"
  export HAS_APP_PRIVATE_KEY=false
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"App auth half-configured"* ]]
}

@test "HAS_APP_PRIVATE_KEY must be true or false" {
  export HAS_APP_PRIVATE_KEY=maybe
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"HAS_APP_PRIVATE_KEY must be true or false"* ]]
}

@test "config_path accepts default and emits validated value" {
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value config_path)" = ".pre-commit-config.yaml" ]
}

@test "config_path accepts safe relative subpath" {
  export CONFIG_PATH="tools/pre-commit/.pre-commit-config.yaml"
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value config_path)" = "tools/pre-commit/.pre-commit-config.yaml" ]
}

@test "config_path rejects empty value" {
  export CONFIG_PATH=""
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"config_path must not be empty"* ]]
}

@test "config_path rejects absolute path" {
  export CONFIG_PATH="/tmp/.pre-commit-config.yaml"
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"config_path must be relative"* ]]
}

@test "config_path rejects traversal segments" {
  for path in "../.pre-commit-config.yaml" "config/../.pre-commit-config.yaml" "config/.." ".."; do
    export CONFIG_PATH="$path"
    run_preflight
    [ "$status" -ne 0 ]
    [[ "$output" == *"config_path must not contain '..' path traversal segments"* ]]
  done
}

@test "empty pre_commit_version selects latest uvx mode" {
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value use_pinned_pre_commit)" = "false" ]
  [ "$(output_value pre_commit_version)" = "" ]
}

@test "set pre_commit_version selects pinned uvx mode and emits validated version" {
  export PRE_COMMIT_VERSION="4.1.0rc1"
  run_preflight
  [ "$status" -eq 0 ]
  [ "$(output_value use_pinned_pre_commit)" = "true" ]
  [ "$(output_value pre_commit_version)" = "4.1.0rc1" ]
}

@test "pre_commit_version accepts post releases, local suffixes, and epoch marker" {
  for version in "3.7.1.post1" "4.0+x" "1!4.0.0"; do
    export PRE_COMMIT_VERSION="$version"
    run_preflight
    [ "$status" -eq 0 ]
    [ "$(output_value use_pinned_pre_commit)" = "true" ]
    [ "$(output_value pre_commit_version)" = "$version" ]
  done
}

@test "unsafe pre_commit_version characters fail before run-mode output" {
  export PRE_COMMIT_VERSION="1.0; echo bad"
  run_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"pre_commit_version contains unsupported characters"* ]]
  [[ "$output" != *"use_pinned_pre_commit="* ]]
}
