#!/usr/bin/env bats

@test "uv.lock touched — exit 0, prints uv.lock" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/uv-lock-touched.diff
  [ "$status" -eq 0 ]
  [ "$output" = "uv.lock" ]
}

@test "go.mod touched — exit 0, prints go.mod (parser-unreadable ecosystem)" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/go-mod-touched.diff
  [ "$status" -eq 0 ]
  [ "$output" = "go.mod" ]
}

@test "multiple lockfiles — exit 0, prints sorted deduplicated list" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/multiple-touched.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") <(printf 'pyproject.toml\nuv.lock\n')
}

@test "subdir manifest — full path preserved in output" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/subdir-manifest.diff
  [ "$status" -eq 0 ]
  [ "$output" = "services/api/pyproject.toml" ]
}

@test "no lockfile — exit 1, empty stdout" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/no-lockfile.diff
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "workflow YAML touched (.yml) — exit 0, prints path" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/workflow-yaml-touched.diff
  [ "$status" -eq 0 ]
  [ "$output" = ".github/workflows/ci.yml" ]
}

@test "workflow YAML (.yaml) and lockfile mixed — both paths emitted" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/workflow-yaml-and-lockfile.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") <(printf '.github/workflows/release.yaml\nuv.lock\n')
}

@test "empty input — exit 1, empty stdout" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/empty.diff
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "malformed input — exit 2, error to stderr" {
  run bash scripts/diff-touches-lockfile.sh < tests/fixtures/diff-touches-lockfile/not-a-diff.txt
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a unified diff"* ]]
}
