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

@test "emits zero rows for a pnpm diff (npm files are owned by npm-bump-extract)" {
  run bash scripts/extract-deps.sh < tests/fixtures/npm-bump-extract/real-grouped-monorepo.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pnpm engines and resolution lines do not match the pip parser" {
  run bash -c 'bash scripts/extract-deps.sh' <<'EOF'
diff --git a/pnpm-lock.yaml b/pnpm-lock.yaml
--- a/pnpm-lock.yaml
+++ b/pnpm-lock.yaml
@@ -1,3 +1,3 @@ packages:
+  '@commitlint/cli@21.0.2':
+    resolution: {integrity: sha512-AAAA==}
+    engines: {node: '>=22.12.0'}
EOF
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Dockerfile FROM lines (issue #212) ---

# docker_diff <path> <body-lines...>: build a one-hunk unified diff.
docker_diff() {
  local path="$1"; shift
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,1 +1,1 @@\n' "$path" "$path" "$path" "$path"
  printf '%s\n' "$@"
}

@test "dep-rank#266 digest bump yields one docker row" {
  run bash scripts/extract-deps.sh < tests/fixtures/extract-deps/dockerfile-deprank-266.diff
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/extract-deps/dockerfile-deprank-266.tsv
}

@test "only added FROM lines emit rows" {
  run bash -c 'bash scripts/extract-deps.sh' < <(docker_diff Dockerfile ' FROM base:1' '-FROM python:3.12' '+FROM python:3.13')
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13\tdocker' ]
}

@test "registry port is not a tag" {
  run bash scripts/extract-deps.sh < <(docker_diff Dockerfile '+FROM localhost:5000/team/img:1.2')
  [ "$status" -eq 0 ]
  [ "$output" = $'localhost:5000/team/img\t1.2\tdocker' ]
}

@test "lowercase from with platform flag and stage alias" {
  run bash scripts/extract-deps.sh < <(docker_diff Dockerfile '+from --platform=$BUILDPLATFORM python:3.13 as build')
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13\tdocker' ]
}

@test "scratch and earlier stage names are skipped" {
  run bash scripts/extract-deps.sh < <(docker_diff Dockerfile ' FROM golang:1.25 AS builder' '+FROM builder' '+FROM scratch' '+FROM alpine:3.22')
  [ "$status" -eq 0 ]
  [ "$output" = $'alpine\t3.22\tdocker' ]
}

@test "digest-only and untagged references" {
  local d
  d=$(printf 'a%.0s' $(seq 1 64))
  run env LC_ALL=C bash scripts/extract-deps.sh < <(docker_diff Dockerfile "+FROM ghcr.io/astral-sh/uv@sha256:$d" '+FROM debian')
  [ "$status" -eq 0 ]
  # LC_ALL=C pins sort order (locale-dependent otherwise)
  [ "$output" = "$(printf 'debian\tlatest\tdocker\nghcr.io/astral-sh/uv\tsha256:%s\tdocker' "$d")" ]
}

@test "unresolved ARG reference emits a raw row" {
  run bash scripts/extract-deps.sh < <(docker_diff Dockerfile '+FROM ${BASE_IMAGE}')
  [ "$status" -eq 0 ]
  [ "$output" = $'${BASE_IMAGE}\t-\tdocker' ]
}

@test "mixed parsed and unparsed FROM lines both emit rows" {
  run env LC_ALL=C bash scripts/extract-deps.sh < <(docker_diff Dockerfile '+FROM python:3.13' '+FROM \' '+FROM')
  [ "$status" -eq 0 ]
  # LC_ALL=C pins sort order (locale-dependent otherwise)
  [ "$output" = "$(printf 'FROM\t-\tdocker\n\\\t-\tdocker\npython\t3.13\tdocker')" ]
}

@test "FROM in a non-Dockerfile is ignored" {
  run bash scripts/extract-deps.sh < <(docker_diff README.md '+FROM python:3.13')
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "CRLF Dockerfile lines parse" {
  run bash scripts/extract-deps.sh < <(docker_diff Dockerfile $'+FROM python:3.13\r')
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13\tdocker' ]
}

@test "self-aliased stage line still emits a row" {
  run bash scripts/extract-deps.sh < <(docker_diff Dockerfile '+FROM python AS python')
  [ "$status" -eq 0 ]
  [ "$output" = $'python\tlatest\tdocker' ]
}
