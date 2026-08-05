#!/usr/bin/env bats

# Helper: run the extractor in one mode against a here-string diff.
run_mode() {
  local mode="$1" diff="$2"
  run bash -c "bash scripts/npm-bump-extract.sh --mode=$mode" <<< "$diff"
}

# Helper: run the extractor in one mode against a fixture file.
run_fixture() {
  local mode="$1" fixture="$2"
  run bash scripts/npm-bump-extract.sh "--mode=$mode" < "$fixture"
}

@test "empty input exits 0 with no output in every mode" {
  for mode in deps lockfile-entries cleared-paths; do
    run bash -c "bash scripts/npm-bump-extract.sh --mode=$mode" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "non-diff input exits 2" {
  run_mode deps "this is not a diff"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a unified diff"* ]]
}

@test "missing --mode exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"--mode="* ]]
}

@test "repeated --mode exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh --mode=deps --mode=deps' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"more than once"* ]]
}

@test "unknown argument exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh --mode=deps --bogus' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "unknown mode value exits 2" {
  run bash -c 'bash scripts/npm-bump-extract.sh --mode=nonsense' < /dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}
