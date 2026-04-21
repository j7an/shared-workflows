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

@test "large valid diff does not trip SIGPIPE under pipefail (regression for #50)" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/large-valid.diff
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") tests/fixtures/extract-deps/large-valid.tsv
}

@test "non-empty malformed input exits 2 with unified diff error" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/not-a-diff.txt
  [ "$status" -eq 2 ]
  [ "$output" = "extract-deps.sh: input is not a unified diff" ]
}

@test "extracts 6 deps from uv.lock multi-package diff (issue #52)" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/uv-lock-multi.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/extract-deps/uv-lock-multi.tsv
}

@test "extracts 3 deps from poetry.lock diff (format-awareness beyond uv.lock)" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/poetry-lock.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/extract-deps/poetry-lock.tsv
}
