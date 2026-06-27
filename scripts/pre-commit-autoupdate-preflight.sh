#!/usr/bin/env bash
# pre-commit-autoupdate-preflight.sh - validate workflow inputs and emit
# secret-free primitives for the reusable pre-commit autoupdate workflow.
#
# Inputs (env vars):
#   CONFIG_PATH             pre-commit config path to diff and optionally commit
#   PRE_COMMIT_VERSION      optional pre-commit runner version
#   APP_ID                  caller repo vars.RELEASE_BOT_APP_ID, if configured
#   HAS_APP_PRIVATE_KEY     true when the private key secret is present, else false
#
# Outputs (stdout, GitHub output format):
#   auth_mode
#   config_path
#   use_fallback_caveat
#   use_pinned_pre_commit
#   pre_commit_version

set -euo pipefail

fail() {
  echo "::error::$*" >&2
  exit 1
}

require_bool() {
  local name="$1" value="$2"
  case "$value" in
    true|false) ;;
    *) fail "${name} must be true or false" ;;
  esac
}

contains_traversal_segment() {
  local path="$1"
  case "$path" in
    ..|../*|*/..|*/../*) return 0 ;;
    *) return 1 ;;
  esac
}

CONFIG_PATH="${CONFIG_PATH:-}"
PRE_COMMIT_VERSION="${PRE_COMMIT_VERSION:-}"
APP_ID="${APP_ID:-}"
HAS_APP_PRIVATE_KEY="${HAS_APP_PRIVATE_KEY:-false}"

require_bool "HAS_APP_PRIVATE_KEY" "$HAS_APP_PRIVATE_KEY"

if [ -z "$CONFIG_PATH" ]; then
  fail "config_path must not be empty"
fi

case "$CONFIG_PATH" in
  /*) fail "config_path must be relative: $CONFIG_PATH" ;;
esac

case "$CONFIG_PATH" in
  *$'\n'*|*$'\r'*) fail "config_path must not contain newlines" ;;
esac

if contains_traversal_segment "$CONFIG_PATH"; then
  fail "config_path must not contain '..' path traversal segments: $CONFIG_PATH"
fi

AUTH_MODE="github_token"
USE_FALLBACK_CAVEAT="true"
if [ -n "$APP_ID" ]; then
  if [ "$HAS_APP_PRIVATE_KEY" != "true" ]; then
    fail "App auth half-configured - set both vars.RELEASE_BOT_APP_ID and RELEASE_BOT_PRIVATE_KEY, or neither."
  fi
  AUTH_MODE="app"
  USE_FALLBACK_CAVEAT="false"
fi

USE_PINNED_PRE_COMMIT="false"
if [ -n "$PRE_COMMIT_VERSION" ]; then
  case "$PRE_COMMIT_VERSION" in
    *[!A-Za-z0-9.+_!-]*)
      fail "pre_commit_version contains unsupported characters (allowed: A-Z a-z 0-9 . + _ ! -)"
      ;;
  esac
  USE_PINNED_PRE_COMMIT="true"
fi

printf 'auth_mode=%s\n' "$AUTH_MODE"
printf 'config_path=%s\n' "$CONFIG_PATH"
printf 'use_fallback_caveat=%s\n' "$USE_FALLBACK_CAVEAT"
printf 'use_pinned_pre_commit=%s\n' "$USE_PINNED_PRE_COMMIT"
printf 'pre_commit_version=%s\n' "$PRE_COMMIT_VERSION"
