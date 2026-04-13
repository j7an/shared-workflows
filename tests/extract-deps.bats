#!/usr/bin/env bats

@test "extracts all three actions from nexus-mcp#160 diff (regression for #27)" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/nexus-mcp-160.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/extract-deps/nexus-mcp-160.tsv
}

@test "extracts Python deps from requirements.txt diff" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/python-requirements.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/extract-deps/python-requirements.tsv
}

@test "empty diff produces empty output with exit 0" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/empty.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
