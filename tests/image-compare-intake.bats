#!/usr/bin/env bats
# image-compare-intake.bats — handoff validation script, the `image comparison
# intake` workflow block, and its wiring into the safety verdict.

WF=.github/workflows/dependency-safety.yml
T=$'\t'

setup() {
  EXPECTED="$BATS_TEST_TMPDIR/expected.tsv"
  printf 'nginx\t1.27\nredis\t7.2\n' >"$EXPECTED"
}

extract_named_block() {
  local yaml="$1" name="$2"
  awk -v n="$name" '
    $0 ~ ("# --- BEGIN " n " ---") {flag=1; next}
    $0 ~ ("# --- END " n " ---")   {exit}
    flag {print}
  ' "$yaml" | sed -E 's/^          //'
}

pair() { printf 'pair\t%s\t%s\t%s\t%s\tlinux/amd64\t%s\n' "$1" "$2" "$3" "$4" "$5"; }
vuln() { # new ver old oldver direction fixability class id pkg inst fixed sev
  printf 'vuln\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

intake() { bash scripts/image-compare-intake.sh "$EXPECTED"; }

@test "all expected images ok -> image rows ok plus passthrough" {
  {
    pair nginx 1.27 nginx 1.26 ok
    vuln nginx 1.27 nginx 1.26 introduced fixable os CVE-2024-1 libc 1.0 1.1 HIGH
    pair redis 7.2 redis 7.1 ok
  } >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "image${T}nginx${T}1.27${T}ok" ]
  [ "${lines[1]}" = "image${T}redis${T}7.2${T}ok" ]
  [ "${lines[2]}" = "$(pair nginx 1.27 nginx 1.26 ok)" ]
  [ "${lines[3]}" = "$(vuln nginx 1.27 nginx 1.26 introduced fixable os CVE-2024-1 libc 1.0 1.1 HIGH)" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "expected image without pair -> missing-comparison" {
  pair nginx 1.27 nginx 1.26 ok | { run intake; [ "$status" -eq 0 ]; [[ "$output" == *"image${T}redis${T}7.2${T}missing-comparison"* ]]; }
}

@test "empty handoff -> every image missing-comparison" {
  run intake </dev/null
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "image${T}nginx${T}1.27${T}missing-comparison" ]
  [ "${lines[1]}" = "image${T}redis${T}7.2${T}missing-comparison" ]
}

@test "one ref with two pairs, one failing -> image status is the failing reason" {
  {
    pair nginx 1.27 nginx 1.26 ok
    pair nginx 1.27 nginx 1.25 trivy-failed
    pair redis 7.2 redis 7.1 ok
  } >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "image${T}nginx${T}1.27${T}trivy-failed" ]
  [ "${lines[1]}" = "image${T}redis${T}7.2${T}ok" ]
}

@test "pair for unexpected image -> exit 2, no stdout" {
  pair apache 2.4 apache 2.3 ok >"$BATS_TEST_TMPDIR/in"
  run --separate-stderr intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "ok pair alongside pairing-ambiguous pair with - old fields -> accepted" {
  {
    pair nginx 1.27 nginx 1.26 ok
    printf 'pair\tredis\t7.2\t-\t-\tlinux/amd64\tpairing-ambiguous\n'
  } >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "image${T}nginx${T}1.27${T}ok" ]
  [ "${lines[1]}" = "image${T}redis${T}7.2${T}pairing-ambiguous" ]
}

@test "- old fields on an ok pair -> exit 2" {
  printf 'pair\tnginx\t1.27\t-\t-\tlinux/amd64\tok\n' >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
}

@test "pkg containing | or backtick -> exit 2" {
  vuln nginx 1.27 nginx 1.26 introduced fixable os CVE-1 'li|b' 1.0 1.1 HIGH >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
  vuln nginx 1.27 nginx 1.26 introduced fixable os CVE-1 'li`b' 1.0 1.1 HIGH >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
}

@test "vuln row with 12 columns -> exit 2" {
  printf 'vuln\tnginx\t1.27\tnginx\t1.26\tintroduced\tfixable\tos\tCVE-1\tlibc\t1.0\tHIGH\n' >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
}

@test "severity outside set -> exit 2" {
  vuln nginx 1.27 nginx 1.26 introduced fixable os CVE-1 libc 1.0 1.1 SEVERE >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
}

@test "empty fields and unknown row types -> exit 2" {
  pair nginx 1.27 '' 1.26 ok >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
  printf 'other\tx\n' >"$BATS_TEST_TMPDIR/in"
  run intake <"$BATS_TEST_TMPDIR/in"
  [ "$status" -eq 2 ]
}

# --- block tests -----------------------------------------------------------

# Run the intake block with a given IMAGE_COUNT / result / base64 payload.
run_block() { # <count> <result> <payload-file or "">
  local count="$1" result="$2" payload=""
  if [ -n "${3:-}" ]; then payload=$(base64 <"$3" | tr -d '\n'); fi
  extract_named_block "$WF" "image comparison intake" >"$BATS_TEST_TMPDIR/block.sh"
  [ -s "$BATS_TEST_TMPDIR/block.sh" ]
  cat >"$BATS_TEST_TMPDIR/harness.sh" <<HARNESS
image_compare_intake() { bash scripts/image-compare-intake.sh "\$@"; }
IMAGE_COUNT=$count
IMAGE_ROWS=\$(cat "$EXPECTED")
IMAGE_COMPARE_RESULT=$result
IMAGE_COMPARE_OUTPUT='$payload'
SCAN_ERROR_COUNT=3
HAS_ERROR=""
. "$BATS_TEST_TMPDIR/block.sh"
printf 'ERRS=%s FIX=%s SCAN=%s HAS=%s\n' "\$IMAGE_COMPARE_ERROR_COUNT" "\$IMAGE_FIXABLE_INTRODUCED_COUNT" "\$SCAN_ERROR_COUNT" "\$HAS_ERROR"
printf '%s\n' "\$IMAGE_COMPARE_TSV"
HARNESS
  run bash "$BATS_TEST_TMPDIR/harness.sh"
}

@test "block: IMAGE_COUNT=0 with failed job -> counts 0, SCAN_ERROR_COUNT unchanged" {
  run_block 0 failure ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRS=0 FIX=0 SCAN=3 HAS="* ]]
  [[ "$output" != *"HAS=true"* ]]
}

@test "block: skipped/failed job -> every image errors" {
  for r in skipped failure cancelled; do
    run_block 2 "$r" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"ERRS=2 FIX=0 SCAN=5 HAS=true"* ]]
    [[ "$output" == *"image${T}nginx${T}1.27${T}image-compare-$r"* ]]
    [[ "$output" == *"image${T}redis${T}7.2${T}image-compare-$r"* ]]
  done
}

@test "block: malformed base64 -> handoff-rejected for every image" {
  printf 'not valid base64 !!!' >"$BATS_TEST_TMPDIR/payload"
  # feed raw (not re-encoded) garbage through the env var
  extract_named_block "$WF" "image comparison intake" >"$BATS_TEST_TMPDIR/block.sh"
  run bash -c '
    image_compare_intake() { bash scripts/image-compare-intake.sh "$@"; }
    IMAGE_COUNT=2; IMAGE_ROWS=$(cat "$1"); IMAGE_COMPARE_RESULT=success
    IMAGE_COMPARE_OUTPUT="@@@not-base64@@@"; SCAN_ERROR_COUNT=0; HAS_ERROR=""
    . "$2"
    printf "ERRS=%s HAS=%s\n%s\n" "$IMAGE_COMPARE_ERROR_COUNT" "$HAS_ERROR" "$IMAGE_COMPARE_TSV"
  ' _ "$EXPECTED" "$BATS_TEST_TMPDIR/block.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRS=2 HAS=true"* ]]
  [[ "$output" == *"image${T}nginx${T}1.27${T}handoff-rejected"* ]]
}

@test "block: rejected (valid base64, bad content) -> handoff-rejected" {
  pair apache 2.4 apache 2.3 ok >"$BATS_TEST_TMPDIR/p"
  run_block 2 success "$BATS_TEST_TMPDIR/p"
  [[ "$output" == *"ERRS=2 FIX=0 SCAN=5 HAS=true"* ]]
  [[ "$output" == *"image${T}redis${T}7.2${T}handoff-rejected"* ]]
}

@test "block: two introduced fixable + one introduced unfixed -> FIXABLE=2" {
  {
    pair nginx 1.27 nginx 1.26 ok
    pair redis 7.2 redis 7.1 ok
    vuln nginx 1.27 nginx 1.26 introduced fixable os CVE-1 libc 1.0 1.1 HIGH
    vuln nginx 1.27 nginx 1.26 introduced fixable lang CVE-2 foo 1.0 1.1 LOW
    vuln redis 7.2 redis 7.1 introduced unfixed os CVE-3 bar 1.0 - LOW
    vuln redis 7.2 redis 7.1 fixed fixable os CVE-4 baz 1.0 1.1 LOW
  } >"$BATS_TEST_TMPDIR/p"
  run_block 2 success "$BATS_TEST_TMPDIR/p"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERRS=0 FIX=2 SCAN=3 HAS="* ]]
}

# --- verdict wiring ----------------------------------------------------------

verdict() { # <scan_errors> <advisory> <policy>
  GUARD_TRIGGERED=false AGE_ERROR_COUNT=0 AGE_VIOLATION_COUNT=0 \
    SCAN_ERROR_COUNT="$1" ADVISORY_COUNT="$2" RELEASE_AGE_POLICY="$3" \
    MINIMUM_RELEASE_AGE_DAYS=5 AUTO_MERGE=true IMAGE_COUNT=2 \
    bash scripts/safety-verdict.sh
}

@test "verdict: fixable introduced under advisory -> success, security review, no auto-merge" {
  run verdict 0 2 advisory
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r gate auto err _age rev _desc <<<"$output"
  [ "$gate" = "success" ]
  [ "$auto" = "false" ]
  [ "$rev" = "true" ]
}

@test "verdict: comparison error under off -> error with has_safety_error" {
  run verdict 2 0 off
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r gate auto err _age rev _desc <<<"$output"
  [ "$gate" = "error" ]
  [ "$auto" = "false" ]
  [ "$err" = "true" ]
}

@test "verdict: clean comparison under off -> release age not checked" {
  run verdict 0 0 off
  [ "$status" -eq 0 ]
  IFS=$'\t' read -r gate auto err _age rev desc <<<"$output"
  [ "$gate" = "error" ]
  [ "$auto" = "false" ]
  [ "$err" = "false" ]
  [[ "$desc" == *"Release age not checked"* ]]
}

@test "workflow passes image fixable count into ADVISORY_COUNT, TOTAL stays package-only" {
  grep -qF 'ADVISORY_COUNT="$((TOTAL + IMAGE_FIXABLE_INTRODUCED_COUNT))"' "$WF"
}
