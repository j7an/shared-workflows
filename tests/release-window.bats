#!/usr/bin/env bats

HELPER_DIR="$BATS_TEST_DIRNAME/../actions/release-window"

py() {
  PYTHONPATH="$HELPER_DIR" python3 - "$@"
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
