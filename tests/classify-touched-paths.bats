#!/usr/bin/env bats

@test "empty input — exit 0, empty stdout" {
  run bash -c 'printf "" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "single supported workflow yml — empty output" {
  run bash -c 'printf ".github/workflows/ci.yml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "single supported workflow yaml — empty output" {
  run bash -c 'printf ".github/workflows/release.yaml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-workflow *.yml is unsupported" {
  run bash -c 'printf "mypkg/config.yml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "mypkg/config.yml" ]
}

@test "uv.lock at root — supported" {
  run bash -c 'printf "uv.lock\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "uv.lock in subdir — supported (basename match)" {
  run bash -c 'printf "subdir/uv.lock\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "poetry.lock — supported" {
  run bash -c 'printf "poetry.lock\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "requirements.txt — supported" {
  run bash -c 'printf "requirements.txt\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "requirements-dev.txt — supported (glob match)" {
  run bash -c 'printf "requirements-dev.txt\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Path-only classifier marks pyproject.toml unsupported. The
# dependency-safety workflow may clear it via
# scripts/pyproject-bump-extract.sh after diff inspection (issue #66);
# this test exercises the classifier in isolation.
@test "pyproject.toml — unsupported (path-only)" {
  run bash -c 'printf "pyproject.toml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "pyproject.toml" ]
}

@test "Pipfile — unsupported" {
  run bash -c 'printf "Pipfile\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "Pipfile" ]
}

@test "Pipfile.lock — unsupported by default (no *.lock catch-all)" {
  run bash -c 'printf "Pipfile.lock\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "Pipfile.lock" ]
}

@test "package.json — unsupported" {
  run bash -c 'printf "package.json\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "package.json" ]
}

@test "package-lock.json — unsupported" {
  run bash -c 'printf "package-lock.json\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "package-lock.json" ]
}

@test "yarn.lock — unsupported by default (no *.lock catch-all)" {
  run bash -c 'printf "yarn.lock\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "yarn.lock" ]
}

@test "pnpm-lock.yaml — unsupported" {
  run bash -c 'printf "pnpm-lock.yaml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "pnpm-lock.yaml" ]
}

@test "go.mod — unsupported" {
  run bash -c 'printf "go.mod\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "go.mod" ]
}

@test "Cargo.toml — unsupported" {
  run bash -c 'printf "Cargo.toml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "Cargo.toml" ]
}

@test "Cargo.lock — unsupported" {
  run bash -c 'printf "Cargo.lock\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "Cargo.lock" ]
}

@test "mixed supported+unsupported (issue #62) — only unsupported emitted" {
  run bash -c 'printf "uv.lock\npackage-lock.json\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "package-lock.json" ]
}

@test "mixed requirements.txt + pyproject.toml — only pyproject emitted" {
  run bash -c 'printf "requirements.txt\npyproject.toml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "pyproject.toml" ]
}

@test "mixed actions + Cargo.toml — only Cargo emitted" {
  run bash -c 'printf ".github/workflows/ci.yml\nCargo.toml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "Cargo.toml" ]
}

@test "duplicate input — deduplicated" {
  run bash -c 'printf "Cargo.toml\nCargo.toml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "Cargo.toml" ]
}

@test "output is sorted" {
  run bash -c 'printf "pnpm-lock.yaml\nCargo.toml\n" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  diff <(echo "$output") <(printf 'Cargo.toml\npnpm-lock.yaml\n')
}

@test "input without trailing newline — final record still emitted" {
  run bash -c 'printf "package-lock.json" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "package-lock.json" ]
}

@test "multiple records, last without trailing newline — all emitted" {
  run bash -c 'printf "uv.lock\npackage-lock.json" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ "$output" = "package-lock.json" ]
}
