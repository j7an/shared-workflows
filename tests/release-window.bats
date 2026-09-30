#!/usr/bin/env bats

HELPER_DIR="$BATS_TEST_DIRNAME/../actions/release-window"
ACTION='actions/release-window/action.yml'

py() {
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$HELPER_DIR" python3 - "$@"
}

input_block() {
  awk -v wanted="$1" '
    /^inputs:$/ { in_inputs = 1; next }
    in_inputs && /^[^[:space:]]/ { exit }
    in_inputs && /^  [^[:space:]][^:]*:$/ {
      if (found) exit
      name = $0
      sub(/^  /, "", name)
      sub(/:$/, "", name)
      if (name == wanted) found = 1
    }
    found { print }
  ' "$ACTION"
}

step_block() {
  awk -v wanted="$1" '
    /^    - id: / {
      if (found) exit
      if ($3 == wanted) found = 1
    }
    found { print }
  ' "$ACTION"
}

reject_input() {
  local expected="$1"
  shift
  run env -i PATH="$PATH" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" "$@" python3 "$HELPER_DIR/release_window.py"
  [ "$status" -eq 1 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
  [[ "$output" == ::error::*"$expected"* ]] || return 1
  [ ! -s "$BATS_TEST_TMPDIR/out" ] || return 1
}

@test "window keeps newest minor plus minors replaced within the window" {
  run py <<'PY'
from datetime import datetime
from release_window import window

def t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

released = {
    "1.83.0": "2026-07-29T22:30:23.309Z", "1.84.0": "2026-08-06T11:10:04.579Z",
    "1.84.1": "2026-08-07T06:01:32.966Z", "1.84.2": "2026-08-14T10:09:06.966Z",
    "1.84.3": "2026-08-24T11:09:37.600Z", "1.84.4": "2026-08-28T22:07:57.753Z",
    "1.85.0": "2026-09-04T10:18:05.208Z", "1.85.1": "2026-09-05T12:17:19.281Z",
    "1.86.0": "2026-09-19T23:14:16.198Z", "1.86.1": "2026-09-20T11:16:39.121Z",
    "1.87.0": "2026-09-21T16:51:53.584Z", "1.87.1": "2026-09-22T19:42:48.221Z",
}
times = {version: t(date) for version, date in released.items()}
result = window(times, t("2026-09-23T00:00:00Z"), 30)
assert result == ["1.87.1", "1.86.1", "1.85.1", "1.84.4"], result
result = window(times, t("2026-10-05T12:00:00Z"), 30)
assert result == ["1.87.1", "1.86.1", "1.85.1"], result
PY
  [ "$status" -eq 0 ] || return 1
}

@test "window handles backport, missing .0, numeric patch order, prerelease, metadata, boundary" {
  run py <<'PY'
from datetime import datetime
from release_window import window

def t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

time = {
    "created": "2026-01-01T00:00:00.000Z", "modified": "2026-02-20T00:00:00.000Z",
    "1.1.0": "2026-01-01T00:00:00.000Z", "1.2.1": "2026-01-31T00:00:00.000Z",
    "1.2.9": "2026-02-05T00:00:00.000Z", "1.3.0": "2026-02-10T00:00:00.000Z",
    "1.2.10": "2026-02-15T00:00:00.000Z", "1.4.0-beta.1": "2026-02-20T00:00:00.000Z",
}
result = window({version: t(date) for version, date in time.items()}, t("2026-03-02T00:00:00Z"), 30)
assert result == ["1.3.0", "1.2.10", "1.1.0"], result
PY
  [ "$status" -eq 0 ] || return 1
}

@test "window keys v-prefixed tags and breaks patch ties deterministically" {
  run py <<'PY'
from datetime import datetime
from release_window import window

def t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

times = {
    "v6.4.2": t("2026-09-25T00:00:00Z"),
    "6.4.2": t("2026-09-25T00:00:00Z"),
    "v6.3.0": t("2026-08-12T00:00:00Z"),
}
for data in (times, dict(reversed(list(times.items())))):
    result = window(data, t("2026-09-29T00:00:00Z"), 90)
    assert result == ["6.4.2", "v6.3.0"], result
PY
  [ "$status" -eq 0 ] || return 1
}

@test "window with fewer than two versions raises WindowError" {
  run py <<'PY'
from datetime import datetime
from release_window import WindowError, window

def t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()

for times, found in (
    ({"1.0.0": t("2026-01-01T00:00:00Z"), "1.1.0": t("2026-01-02T00:00:00Z")}, ["1.1.0"]),
    ({}, []),
    ({"2.0.0-rc.1": t("2026-01-01T00:00:00Z")}, []),
):
    try:
        window(times, t("2026-03-01T00:00:00Z"), 30)
    except WindowError as exc:
        assert "increase window-days" in str(exc), exc
        assert "at least 2" in str(exc), exc
        for version in found:
            assert version in str(exc), exc
    else:
        raise AssertionError("expected WindowError")
PY
  [ "$status" -eq 0 ] || return 1
}

@test "npm_url encodes scoped names" {
  run py <<'PY'
from release_window import npm_url
assert npm_url("@earendil-works/pi-coding-agent") == "https://registry.npmjs.org/@earendil-works%2fpi-coding-agent"
assert npm_url("typescript") == "https://registry.npmjs.org/typescript"
PY
  [ "$status" -eq 0 ] || return 1
}

@test "npm_times parses Z timestamps and feeds window" {
  run py <<'PY'
from datetime import datetime, timezone
from release_window import npm_times, window

doc = {"versions": {"1.0.0": {}, "1.1.0": {}}, "time": {
    "created": "2026-01-01T00:00:00.000Z", "modified": "2026-02-20T00:00:00.000Z",
    "1.0.0": "2026-01-01T00:00:00.000Z", "1.1.0": "2026-02-10T00:00:00.000Z",
}}
times = npm_times(doc)
assert times["1.1.0"] == datetime(2026, 2, 10, tzinfo=timezone.utc).timestamp(), times
result = window(times, datetime(2026, 2, 20, tzinfo=timezone.utc).timestamp(), 30)
assert result == ["1.1.0", "1.0.0"], result
PY
  [ "$status" -eq 0 ] || return 1
}

@test "npm_times excludes unpublished patches and minors from the window" {
  run py <<'PY'
from datetime import datetime, timezone
from release_window import npm_times, window

doc = {
    "versions": {"1.0.0": {}, "1.1.1": {}},
    "time": {
        "created": "2026-01-01T00:00:00.000Z",
        "modified": "2026-02-20T00:00:00.000Z",
        "1.0.0": "2026-01-01T00:00:00.000Z",
        "1.1.1": "2026-02-10T00:00:00.000Z",
        "1.1.2": "2026-02-15T00:00:00.000Z",
        "1.2.0": "2026-02-16T00:00:00.000Z",
    },
}
times = npm_times(doc)
assert set(times) == {"1.0.0", "1.1.1"}, times
result = window(times, datetime(2026, 2, 20, tzinfo=timezone.utc).timestamp(), 30)
assert result == ["1.1.1", "1.0.0"], result
PY
  [ "$status" -eq 0 ] || return 1
}

@test "npm_times rejects a document without a time map" {
  run py <<'PY'
from release_window import npm_times

for doc in ({}, {"time": None}, {"time": []}, {"versions": {"1.0.0": {}}, "time": {"1.0.0": "bad-date"}}):
    try:
        npm_times(doc)
    except ValueError:
        pass
    else:
        raise AssertionError(f"expected ValueError for {doc}")
PY
  [ "$status" -eq 0 ] || return 1
}

@test "git_times reads annotated tag dates from a local repo" {
  repo="$BATS_TEST_TMPDIR/repo"
  mkdir "$repo" || return 1
  git_args=(-C "$repo" -c user.name='Release Window Test' -c user.email=release-window@example.invalid -c commit.gpgsign=false -c tag.gpgSign=false)
  git "${git_args[@]}" init -q || return 1
  git "${git_args[@]}" commit --allow-empty -qm fixture || return 1
  while read -r tag date; do
    GIT_COMMITTER_DATE="$date" git "${git_args[@]}" tag -a "$tag" -m "$tag" || return 1
  done <<'TAGS'
v6.3.0 2026-08-12T00:00:00Z
6.4.0 2026-09-19T00:00:00Z
v6.4.2 2026-09-25T00:00:00Z
v7.0.0-rc.1 2026-09-27T00:00:00Z
latest 2026-09-28T00:00:00Z
TAGS
  blob=$(printf 'not a release' | git "${git_args[@]}" hash-object -w --stdin) || return 1
  git "${git_args[@]}" tag latest-blob "$blob" || return 1
  run py "$repo" <<'PY'
import sys
from datetime import datetime, timezone
from release_window import git_times, window

times = git_times(sys.argv[1])
assert "6.4.0" in times, times
assert "latest" not in times, times
assert "v7.0.0-rc.1" not in times, times
assert "latest-blob" not in times, times
assert times["v6.4.2"] == datetime(2026, 9, 25, tzinfo=timezone.utc).timestamp(), times
result = window(times, datetime(2026, 9, 29, tzinfo=timezone.utc).timestamp(), 90)
assert result == ["v6.4.2", "v6.3.0"], result
PY
  [ "$status" -eq 0 ] || return 1
}

@test "main rejects invalid inputs before fetching" {
  reject_input 'exactly one' RELEASE_WINDOW_DAYS=30 || return 1
  reject_input 'exactly one' RELEASE_WINDOW_DAYS=30 RELEASE_WINDOW_NPM_PACKAGE=typescript RELEASE_WINDOW_GIT_URL=https://github.com/obra/superpowers || return 1
  reject_input 'npm-package' RELEASE_WINDOW_DAYS=30 RELEASE_WINDOW_NPM_PACKAGE='Bad Name' || return 1
  reject_input 'git-url' RELEASE_WINDOW_DAYS=30 RELEASE_WINDOW_GIT_URL=http://github.com/obra/superpowers || return 1
  reject_input 'git-url' RELEASE_WINDOW_DAYS=30 RELEASE_WINDOW_GIT_URL=$'https://example.invalid/\n::warning::injected' || return 1
  for days in '' 0 abc 1.5 -3 ' 30' +30; do
    reject_input 'positive integer' RELEASE_WINDOW_NPM_PACKAGE=typescript "RELEASE_WINDOW_DAYS=$days" || return 1
  done
}

@test "main reports an unreachable git remote as one escaped error line" {
  run env -i PATH="$PATH" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" RUNNER_TEMP="$BATS_TEST_TMPDIR" RELEASE_WINDOW_GIT_URL=https://127.0.0.1:9/x RELEASE_WINDOW_DAYS=30 python3 "$HELPER_DIR/release_window.py"
  [ "$status" -eq 1 ] || return 1
  [ "${#lines[@]}" -eq 1 ] || return 1
  [[ "$output" == ::error::* ]] || return 1
  [[ "$output" != *Traceback* ]] || return 1
  [ ! -s "$BATS_TEST_TMPDIR/out" ] || return 1
  [ -z "$(find "$BATS_TEST_TMPDIR" -mindepth 1 -type d -print)" ] || return 1
}

@test "error escapes workflow-command separators" {
  run py <<'PY'
from release_window import error
error("a%b\r\n::warning::x")
PY
  [ "$status" -eq 0 ] || return 1
  [ "$output" = '::error::a%25b%0D%0A::warning::x' ] || return 1
}

@test "main reports a truncated npm response as one error line" {
  run py "$BATS_TEST_TMPDIR/out" <<'PY'
from contextlib import redirect_stdout
from http.client import HTTPResponse
import io
import os
import sys
from unittest.mock import patch
from release_window import main

class Socket:
    def makefile(self, mode):
        return io.BytesIO(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{}")

response = HTTPResponse(Socket())
response.begin()
output = io.StringIO()
env = {"RELEASE_WINDOW_NPM_PACKAGE": "typescript", "RELEASE_WINDOW_DAYS": "30", "GITHUB_OUTPUT": sys.argv[1]}
with patch.dict(os.environ, env, clear=True), patch("urllib.request.urlopen", return_value=response), redirect_stdout(output):
    result = main()
assert result == 1, result
lines = output.getvalue().splitlines()
assert len(lines) == 1 and lines[0].startswith("::error::IncompleteRead"), lines
assert not os.path.exists(sys.argv[1]), sys.argv[1]
PY
  [ "$status" -eq 0 ] || return 1
}

@test "release-window action exposes three inputs and one output" {
  run awk '/^inputs:$/ { yes=1; next } yes && /^[^[:space:]]/ { exit } yes && /^  [^[:space:]][^:]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$ACTION"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = $'npm-package\ngit-url\nwindow-days' ] || return 1
  for input in npm-package git-url; do
    [[ "$(input_block "$input")" != *'required: true'* ]] || return 1
  done
  [[ "$(input_block window-days)" == *'required: true'* ]] || return 1
  [[ "$(input_block window-days)" != *'default:'* ]] || return 1
  run awk '/^outputs:$/ { yes=1; next } yes && /^[^[:space:]]/ { exit } yes && /^  [^[:space:]][^:]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$ACTION"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = versions ] || return 1
  grep -Fq 'value: ${{ steps.window.outputs.versions }}' "$ACTION" || return 1
}

@test "release-window action is composite and passes inputs as environment data" {
  grep -q '^  using: composite$' "$ACTION" || return 1
  block="$(step_block window)"
  [[ "$block" == *'shell: bash'* ]] || return 1
  [[ "$block" == *'run: python3 "$GITHUB_ACTION_PATH/release_window.py"'* ]] || return 1
  [[ "$block" == *'RELEASE_WINDOW_NPM_PACKAGE: ${{ inputs.npm-package }}'* ]] || return 1
  [[ "$block" == *'RELEASE_WINDOW_GIT_URL: ${{ inputs.git-url }}'* ]] || return 1
  [[ "$block" == *'RELEASE_WINDOW_DAYS: ${{ inputs.window-days }}'* ]] || return 1
  ! grep -E '^[[:space:]]*run:.*inputs\.' "$ACTION" || return 1
}
