#!/usr/bin/env bats

FX=tests/fixtures/docker-image-pairs
T=$'\t'

@test "deprank-266 single digest bump pairs" {
  run bash scripts/docker-image-pairs.sh < tests/fixtures/extract-deps/dockerfile-deprank-266.diff
  [ "$status" -eq 0 ]
  old=3.13-slim@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962
  new=3.13-slim@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90
  [ "$output" = "Dockerfile${T}python${T}${old}${T}python${T}${new}${T}ok" ]
}

@test "multi-stage: two FROM bumps pair by position" {
  run bash scripts/docker-image-pairs.sh < $FX/multistage.diff
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile${T}golang${T}1.23${T}golang${T}1.24${T}ok
Dockerfile${T}alpine${T}3.20${T}alpine${T}3.21${T}ok" ]
}

@test "stage alias and scratch are skipped on both sides" {
  run bash scripts/docker-image-pairs.sh < $FX/skip-stage-scratch.diff
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile${T}alpine${T}3.20${T}alpine${T}3.21${T}ok" ]
}

@test "--platform flag and AS alias are parsed" {
  run bash scripts/docker-image-pairs.sh < $FX/platform-alias.diff
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile${T}golang${T}1.23${T}golang${T}1.24${T}ok" ]
}

@test "added FROM with no removed FROM is pairing-ambiguous" {
  run bash scripts/docker-image-pairs.sh < $FX/added-only.diff
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile${T}-${T}-${T}alpine${T}3.21${T}pairing-ambiguous" ]
}

@test "removed/added count mismatch makes every added row pairing-ambiguous" {
  run bash scripts/docker-image-pairs.sh < $FX/count-mismatch.diff
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile${T}-${T}-${T}alpine${T}3.21${T}pairing-ambiguous
Dockerfile${T}-${T}-${T}golang${T}1.24${T}pairing-ambiguous" ]
}

@test "unparseable removed reference is unparseable-reference" {
  run bash scripts/docker-image-pairs.sh < $FX/removed-unparseable.diff
  [ "$status" -eq 0 ]
  [ "$output" = "Dockerfile${T}-${T}-${T}alpine${T}3.21${T}unparseable-reference" ]
}

@test "unparseable added reference emits no row" {
  run bash scripts/docker-image-pairs.sh < $FX/added-unparseable.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "non-FROM Dockerfile edit produces no output" {
  run bash scripts/docker-image-pairs.sh < $FX/non-from-edit.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "two Dockerfiles bump the same image from different old refs" {
  run bash scripts/docker-image-pairs.sh < $FX/two-dockerfiles.diff
  [ "$status" -eq 0 ]
  [ "$output" = "svc/a/Dockerfile${T}python${T}3.12-slim${T}python${T}3.13-slim${T}ok
svc/b/Dockerfile${T}python${T}3.11-slim${T}python${T}3.13-slim${T}ok" ]
}

@test "non-Dockerfile files are ignored" {
  run bash scripts/docker-image-pairs.sh < $FX/non-dockerfile.diff
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty input exits 0 with no output" {
  run bash scripts/docker-image-pairs.sh < /dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "garbage input exits 2" {
  run bash scripts/docker-image-pairs.sh < $FX/not-a-diff.txt
  [ "$status" -eq 2 ]
}

@test "parsing parity with extract-deps: new image columns match docker rows" {
  for f in tests/fixtures/extract-deps/dockerfile-deprank-266.diff \
           $FX/multistage.diff $FX/skip-stage-scratch.diff $FX/platform-alias.diff \
           $FX/removed-unparseable.diff $FX/two-dockerfiles.diff; do
    expected=$(bash scripts/extract-deps.sh < "$f" | awk -F'\t' '$3=="docker"{print $1 "\t" $2}' | sort -u)
    actual=$(bash scripts/docker-image-pairs.sh < "$f" | awk -F'\t' '$6=="ok" || $6=="unparseable-reference"{print $4 "\t" $5}' | sort -u)
    [ -n "$expected" ]
    [ "$expected" = "$actual" ]
  done
}
