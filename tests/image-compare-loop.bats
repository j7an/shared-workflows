#!/usr/bin/env bats

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  ROOT=$PWD
  FX=$ROOT/tests/fixtures/image-vuln-diff
  T=$BATS_TEST_TMPDIR
  mkdir -p "$T/bin" "$T/run"
  export RUNNER_TEMP="$T/run" GITHUB_OUTPUT="$T/out"
  : >"$GITHUB_OUTPUT"
  # Fake trivy: writes fixtures by ref; FAIL_REF makes that ref fail with FAIL_MSG.
  cat >"$T/bin/trivy" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$TRIVY_LOG"
case "$1" in
  version) cat "$FX/db-version.json"; exit 0 ;;
esac
if [[ " $* " == *" --download-db-only "* ]]; then exit "${DB_RC:-0}"; fi
out="" ; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) out=$2; shift 2 ;;
    --image-src|--platform|--scanners|--format|--cache-dir) shift 2 ;;
    image|--skip-db-update|--skip-version-check|--list-all-pkgs|--quiet) shift ;;
    *) ref=$1; shift ;;
  esac
done
echo "$ref" >>"$TRIVY_REFS"
if [ "$ref" = "${FAIL_REF:-}" ]; then echo "${FAIL_MSG:-boom}" >&2; exit 1; fi
case "$ref" in
  *old*|*:1.0*) cp "${OLD_FX:-$FX/deprank-266-old.json}" "$out" ;;
  *) cp "${NEW_FX:-$FX/deprank-266-new.json}" "$out" ;;
esac
F
  chmod +x "$T/bin/trivy"
  export PATH="$T/bin:$PATH" FX TRIVY_LOG="$T/trivy.log" TRIVY_REFS="$T/refs"
  : >"$TRIVY_REFS"
  BLOCK=$(awk '/# --- BEGIN image compare loop ---/{f=1;next} /# --- END image compare loop ---/{exit} f{print}' .github/workflows/dependency-safety.yml | sed -E 's/^          //')
}

run_loop() {
  run bash -c "
    set -euo pipefail
    image_vuln_diff() { bash '$ROOT/scripts/image-vuln-diff.sh' \"\$@\"; }
    PAIRS_FILE='$T/pairs.tsv'
    $BLOCK
  "
}

has_line() { grep -qxF -- "$(printf "$1")"; }
decoded() { sed -n 's/^result=//p' "$GITHUB_OUTPUT" | base64 -d; }

@test "ok pair yields pair row and the fixture delta as vuln rows" {
  printf 'Dockerfile\tex/img\t1.0\tex/img\t2.0\tok\n' >"$T/pairs.tsv"
  run_loop
  [ "$status" -eq 0 ]
  out=$(decoded)
  has_line 'pair\tex/img\t2.0\tex/img\t1.0\tlinux/amd64\tok' <<<"$out"
  expected=$(bash scripts/image-vuln-diff.sh $FX/db-version.json $FX/deprank-266-old.json $FX/deprank-266-new.json)
  [ -n "$expected" ]
  actual=$(grep '^vuln' <<<"$out" | cut -f6- | sort)
  [ "$actual" = "$(sort <<<"$expected")" ]
  [ "$(grep '^vuln' <<<"$out" | head -1 | cut -f1-5)" = "$(printf 'vuln\tex/img\t2.0\tex/img\t1.0')" ]
}

@test "trivy failure on one of two pairs gives trivy-failed and the other pair stays ok" {
  printf 'Dockerfile\tex/img\t1.0\tex/img\t2.0\tok\nsub/Dockerfile\tex/bad\t1.0\tex/bad\t2.0\tok\n' >"$T/pairs.tsv"
  FAIL_REF=ex/bad:2.0 run_loop
  [ "$status" -eq 0 ]
  out=$(decoded)
  has_line 'pair\tex/bad\t2.0\tex/bad\t1.0\tlinux/amd64\ttrivy-failed' <<<"$out"
  has_line 'pair\tex/img\t2.0\tex/img\t1.0\tlinux/amd64\tok' <<<"$out"
  if grep -q '^vuln.ex/bad' <<<"$out"; then return 1; fi
  grep -q '^vuln.ex/img' <<<"$out"
}

@test "rate limit in trivy stderr gives docker-rate-limited" {
  printf 'Dockerfile\tex/img\t1.0\tex/img\t2.0\tok\n' >"$T/pairs.tsv"
  local msg
  for msg in "toomanyrequests: TOOMANYREQUESTS pulling" "HTTP 429 Too Many"; do
    : >"$GITHUB_OUTPUT"
    FAIL_REF=ex/img:1.0 FAIL_MSG="$msg" run_loop
    [ "$status" -eq 0 ]
    decoded | has_line 'pair\tex/img\t2.0\tex/img\t1.0\tlinux/amd64\tdocker-rate-limited'
  done
}

@test "diff reason token becomes the pair status" {
  printf 'Dockerfile\tex/img\t1.0\tex/img\t2.0\tok\n' >"$T/pairs.tsv"
  jq '.Results |= map(del(.Packages))' "$FX/deprank-266-new.json" >"$T/empty.json"
  NEW_FX="$T/empty.json" run_loop
  [ "$status" -eq 0 ]
  out=$(decoded)
  has_line 'pair\tex/img\t2.0\tex/img\t1.0\tlinux/amd64\tno-packages-new' <<<"$out"
  [[ $(grep -c '^pair' <<<"$out") -eq 1 ]]
  if grep -q '^vuln' <<<"$out"; then return 1; fi
}

@test "non-ok row from docker-image-pairs passes through as pair status" {
  printf 'Dockerfile\t-\t-\tex/img\t2.0\tpairing-ambiguous\n' >"$T/pairs.tsv"
  run_loop
  [ "$status" -eq 0 ]
  decoded | has_line 'pair\tex/img\t2.0\t-\t-\tlinux/amd64\tpairing-ambiguous'
  [ ! -s "$TRIVY_REFS" ]
}

@test "oversize result collapses to result-too-large pair rows" {
  printf 'Dockerfile\tex/img\t1.0\tex/img\t2.0\tok\n' >"$T/pairs.tsv"
  IMAGE_COMPARE_MAX_BYTES=100 run_loop
  [ "$status" -eq 0 ]
  out=$(decoded)
  [ "$out" = "$(printf 'pair\tex/img\t2.0\tex/img\t1.0\tlinux/amd64\tresult-too-large')" ]
}

@test "default result cap stays below the 128 KiB per-env-string limit" {
  local cap
  cap=$(sed -n 's/.*MAX_RESULT_BYTES="\${IMAGE_COMPARE_MAX_BYTES:-\([0-9]*\)}".*/\1/p' .github/workflows/dependency-safety.yml)
  [ -n "$cap" ]
  [ "$cap" -lt 131072 ]
}

@test "image refs passed to trivy" {
  d=sha256:$(printf 'a%.0s' $(seq 64))
  printf 'Dockerfile\tex/a\t1.0@%s\tex/a\t2.0@%s\tok\nDockerfile\tex/b\t1.0\tex/b\t2.0\tok\nDockerfile\tex/c\t%s\tex/c\t%s\tok\nDockerfile\tex/d\tlatest\tex/d\tlatest\tok\n' "$d" "$d" "$d" "$d" >"$T/pairs.tsv"
  run_loop
  [ "$status" -eq 0 ]
  grep -qxF "ex/a:2.0@$d" "$TRIVY_REFS"
  grep -qxF "ex/b:2.0" "$TRIVY_REFS"
  grep -qxF "ex/c@$d" "$TRIVY_REFS"
  grep -qxF "ex/d:latest" "$TRIVY_REFS"
}

@test "no pairs file rows yields empty output" {
  : >"$T/pairs.tsv"
  run_loop
  [ "$status" -eq 0 ]
  [ -z "$(decoded)" ]
}

@test "DB download failure fails the step" {
  printf 'Dockerfile\tex/img\t1.0\tex/img\t2.0\tok\n' >"$T/pairs.tsv"
  DB_RC=1 run_loop
  [ "$status" -ne 0 ]
}
