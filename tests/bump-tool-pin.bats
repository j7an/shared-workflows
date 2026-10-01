#!/usr/bin/env bats

setup() {
  export TOOL_PIN_NOW=1790812800 # 2026-10-01T00:00:00Z
  fixture="tests/fixtures/bump-tool-pin"
  cp "$fixture"/*.yml "$BATS_TEST_TMPDIR/"
  pin="$BATS_TEST_TMPDIR/pinned.yml"
}

@test "bumps to highest aged stable release" {
  run bash scripts/bump-tool-pin.sh version 5 "$pin" < "$fixture/releases.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'1.26.1\t1.30.1\tv1.30.1\t2026-09-09T05:34:10Z' ]
  sed 's/"1.26.1"/"1.30.1"/' "$fixture/pinned.yml" > "$BATS_TEST_TMPDIR/expected.yml"
  cmp "$pin" "$BATS_TEST_TMPDIR/expected.yml"
  run diff "$fixture/pinned.yml" "$pin"
  [ "$status" -eq 1 ]
  [ "$output" = $'4c4\n<       version: "1.26.1"\n---\n>       version: "1.30.1"' ]
}

@test "skips drafts, flagged prereleases, suffix and non-semver tags" {
  jq '[.[] | select(.draft or .prerelease or .tag_name == "nightly" or .tag_name == "v1.30.0-rc1")]' "$fixture/releases.json" > "$BATS_TEST_TMPDIR/skip.json"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" < "$BATS_TEST_TMPDIR/skip.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$pin" "$fixture/pinned.yml"
}

@test "no downgrade from backport published later" {
  printf '  version: "1.30.1"\n' > "$pin"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" < "$fixture/releases.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no-op when already at latest eligible" {
  printf '  version: "1.30.1"\n' > "$pin"
  cp "$pin" "$BATS_TEST_TMPDIR/before.yml"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" < "$fixture/releases.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$pin" "$BATS_TEST_TMPDIR/before.yml"
}

@test "compares versions numerically" {
  printf '  version: "1.8.0"\n' > "$pin"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" <<'JSON'
[{"tag_name":"1.9.0","published_at":"2026-09-01T00:00:00Z","draft":false,"prerelease":false},{"tag_name":"1.10.0","published_at":"2026-09-01T00:00:00Z","draft":false,"prerelease":false}]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = $'1.8.0\t1.10.0\t1.10.0\t2026-09-01T00:00:00Z' ]
  [ "$(cat "$pin")" = '  version: "1.10.0"' ]
}

@test "handles tags without v prefix" {
  printf '  version: "0.12.10"\n' > "$pin"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" <<'JSON'
[{"tag_name":"0.12.20","published_at":"2026-09-20T00:00:00Z","draft":false,"prerelease":false}]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = $'0.12.10\t0.12.20\t0.12.20\t2026-09-20T00:00:00Z' ]
  [ "$(cat "$pin")" = '  version: "0.12.20"' ]
}

@test "empty release list is a no-op" {
  run bash scripts/bump-tool-pin.sh version 5 "$pin" <<< '[]'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$pin" "$fixture/pinned.yml"
}

@test "rewrites every matching line" {
  local repeated="$BATS_TEST_TMPDIR/repeated.yml"
  run bash scripts/bump-tool-pin.sh bats-version 5 "$repeated" <<'JSON'
[{"tag_name":"v1.15.0","published_at":"2026-09-20T00:00:00Z","draft":false,"prerelease":false}]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = $'1.14.0\t1.15.0\tv1.15.0\t2026-09-20T00:00:00Z' ]
  sed 's/"1.14.0"/"1.15.0"/' "$fixture/repeated.yml" > "$BATS_TEST_TMPDIR/expected.yml"
  cmp "$repeated" "$BATS_TEST_TMPDIR/expected.yml"
}

@test "agrees across multiple files" {
  cp "$pin" "$BATS_TEST_TMPDIR/second.yml"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" "$BATS_TEST_TMPDIR/second.yml" < "$fixture/releases.json"
  [ "$status" -eq 0 ]
  [ "$output" = $'1.26.1\t1.30.1\tv1.30.1\t2026-09-09T05:34:10Z' ]
  sed 's/"1.26.1"/"1.30.1"/' "$fixture/pinned.yml" > "$BATS_TEST_TMPDIR/expected.yml"
  cmp "$pin" "$BATS_TEST_TMPDIR/expected.yml"
  cmp "$BATS_TEST_TMPDIR/second.yml" "$BATS_TEST_TMPDIR/expected.yml"
}

@test "exits 2 on disagreeing values" {
  run bash scripts/bump-tool-pin.sh version 5 "$BATS_TEST_TMPDIR/mismatch.yml" < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  cmp "$BATS_TEST_TMPDIR/mismatch.yml" "$fixture/mismatch.yml"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" "$BATS_TEST_TMPDIR/mismatch.yml" < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  cmp "$pin" "$fixture/pinned.yml"
}

@test "exits 2 when no line matches" {
  run bash scripts/bump-tool-pin.sh absent-version 5 "$pin" < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  cmp "$pin" "$fixture/pinned.yml"
}

@test "exits 2 on malformed input before mutation" {
  local input
  for input in '{}' 'not json' '' '[] []'; do
    run bash scripts/bump-tool-pin.sh version 5 "$pin" <<< "$input"
    [ "$status" -eq 2 ]
    cmp "$pin" "$fixture/pinned.yml"
  done
}

@test "exits 2 on bad arguments before mutation" {
  run bash scripts/bump-tool-pin.sh version x "$pin" < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  run bash scripts/bump-tool-pin.sh version 5 "$pin" "$BATS_TEST_TMPDIR/missing.yml" < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  run bash scripts/bump-tool-pin.sh 'bad key!' 5 "$pin" < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  run bash scripts/bump-tool-pin.sh version 5 < "$fixture/releases.json"
  [ "$status" -eq 2 ]
  cmp "$pin" "$fixture/pinned.yml"
}

@test "accepts age with leading zeros and includes cutoff instant" {
  run bash scripts/bump-tool-pin.sh version 05 "$pin" <<'JSON'
[{"tag_name":"v1.30.1","published_at":"2026-09-26T00:00:00Z","draft":false,"prerelease":false},{"tag_name":"v1.31.0","published_at":"2026-09-26T00:00:01Z","draft":false,"prerelease":false}]
JSON
  [ "$status" -eq 0 ]
  [ "$output" = $'1.26.1\t1.30.1\tv1.30.1\t2026-09-26T00:00:00Z' ]
}

@test "preserves arbitrary expressions containing the old version" {
  cat >> "$pin" <<'YAML'
      version: ${{ inputs.version || '1.26.1' }}
      version: ${{ inputs.version || "1.26.1" }}
YAML
  cp "$pin" "$BATS_TEST_TMPDIR/expected.yml"
  sed 's/^      version: "1.26.1"$/      version: "1.30.1"/' "$BATS_TEST_TMPDIR/expected.yml" > "$BATS_TEST_TMPDIR/rewrite.yml"
  run bash scripts/bump-tool-pin.sh version 5 "$pin" < "$fixture/releases.json"
  [ "$status" -eq 0 ]
  cmp "$pin" "$BATS_TEST_TMPDIR/rewrite.yml"
}

@test "all releases too new leave files unchanged" {
  run bash scripts/bump-tool-pin.sh version 5 "$pin" <<'JSON'
[{"tag_name":"v1.31.0","published_at":"2026-09-29T00:00:00Z","draft":false,"prerelease":false}]
JSON
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$pin" "$fixture/pinned.yml"
}
