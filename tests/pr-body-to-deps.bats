#!/usr/bin/env bats

@test "pattern A — single Bumps line with f-in-URL emits 1 row" {
  # Regression: previously [^f]* stopped at any 'f' in the URL,
  # silently dropping names like `ruff` with `f` in the repo slug.
  run bash scripts/pr-body-to-deps.sh pypi < tests/fixtures/pr-body-to-deps/single-bumps.txt
  [ "$status" -eq 0 ]
  [ "$output" = $'ruff\t0.15.10\tpypi' ]
}

@test "pattern B — prose Updates emits sorted rows" {
  run bash scripts/pr-body-to-deps.sh pypi < tests/fixtures/pr-body-to-deps/prose-updates.txt
  [ "$status" -eq 0 ]
  expected=$'mypy\t1.20.1\tpypi\npydantic\t2.13.0\tpypi'
  [ "$output" = "$expected" ]
}

@test "pattern C — grouped table from nexus-mcp#170 emits 5 rows" {
  run bash scripts/pr-body-to-deps.sh pypi < tests/fixtures/pr-body-to-deps/grouped-table.txt
  [ "$status" -eq 0 ]
  # Must contain all 5 package names in sorted order
  [[ "$output" == *$'mypy\t1.20.1\tpypi'* ]]
  [[ "$output" == *$'pydantic\t2.13.0\tpypi'* ]]
  [[ "$output" == *$'pytest\t9.0.3\tpypi'* ]]
  [[ "$output" == *$'respx\t0.23.1\tpypi'* ]]
  [[ "$output" == *$'ruff\t0.15.10\tpypi'* ]]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "5" ]
  # Sort invariant: mypy is lexicographic smallest of the 5 names → must be first
  [ "$(head -n 1 <<< "$output")" = $'mypy\t1.20.1\tpypi' ]
}

@test "mixed — deduplicates repeated entries" {
  run bash scripts/pr-body-to-deps.sh pypi < tests/fixtures/pr-body-to-deps/mixed.txt
  [ "$status" -eq 0 ]
  expected=$'mypy\t1.20.1\tpypi\npydantic\t2.13.0\tpypi\npytest\t9.0.3\tpypi'
  [ "$output" = "$expected" ]
}

@test "no recognized format — empty stdout, exit 0" {
  run bash scripts/pr-body-to-deps.sh pypi < tests/fixtures/pr-body-to-deps/no-bumps.txt
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "release notes noise — only real bump extracted, no false positive from blockquote" {
  run bash scripts/pr-body-to-deps.sh pypi < tests/fixtures/pr-body-to-deps/release-notes-noise.txt
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ]
  [[ "$output" == *'pydantic'* ]]
  [[ "$output" != *'jiter'* ]]
}

@test "missing ecosystem arg — exit 2" {
  run bash scripts/pr-body-to-deps.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"ecosystem must be"* ]]
}

@test "invalid ecosystem arg — exit 2" {
  run bash scripts/pr-body-to-deps.sh cargo < tests/fixtures/pr-body-to-deps/single-bumps.txt
  [ "$status" -eq 2 ]
  [[ "$output" == *"ecosystem must be"* ]]
}
