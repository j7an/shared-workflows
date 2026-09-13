#!/usr/bin/env bats

@test "empty input — exit 0, empty stdout" {
  run bash -c 'printf "" | bash scripts/classify-touched-paths.sh'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "supported single paths emit no unsupported paths" {
  local path
  for path in .github/workflows/ci.yml .github/workflows/release.yaml \
    uv.lock subdir/uv.lock poetry.lock requirements.txt requirements-dev.txt; do
    run bash -c 'printf "%s\\n" "$1" | bash scripts/classify-touched-paths.sh' _ "$path"
    if [ "$status" -ne 0 ] || [ -n "$output" ]; then
      printf 'supported path failed: %s; status=%s; output=%s\\n' "$path" "$status" "$output" >&2
      return 1
    fi
  done
}

@test "unsupported single paths are emitted unchanged" {
  local path
  # Path-only classification; diff-aware composition may separately clear files.
  for path in mypkg/config.yml pyproject.toml Pipfile Pipfile.lock package.json \
    package-lock.json yarn.lock pnpm-lock.yaml go.mod Cargo.toml Cargo.lock; do
    run bash -c 'printf "%s\\n" "$1" | bash scripts/classify-touched-paths.sh' _ "$path"
    if [ "$status" -ne 0 ] || [ "$output" != "$path" ]; then
      printf 'unsupported path failed: %s; status=%s; output=%s\\n' "$path" "$status" "$output" >&2
      return 1
    fi
  done
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
