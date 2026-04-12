#!/usr/bin/env bats

setup() {
  export AGE_FIXTURE_DIR="tests/fixtures/check-release-age"
  export NOW_EPOCH=1775995200   # 2026-04-12T12:00:00Z — verify with: date -u -r 1775995200
}

@test "blocks sub-cooldown actions at COOLDOWN_DAYS=7 (regression for #25)" {
  export COOLDOWN_DAYS=7
  run bash scripts/check-release-age.sh < tests/fixtures/check-release-age/nexus-mcp-160.tsv
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/check-release-age/nexus-mcp-160-cooldown-7.tsv
}
