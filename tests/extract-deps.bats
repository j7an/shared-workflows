#!/usr/bin/env bats

@test "extracts all three actions from nexus-mcp#160 diff (regression for #27)" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/nexus-mcp-160.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/extract-deps/nexus-mcp-160.tsv
}
