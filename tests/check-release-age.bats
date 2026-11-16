#!/usr/bin/env bats

setup() {
  export AGE_FIXTURE_DIR="tests/fixtures/check-release-age"
  export NOW_EPOCH=1775995200   # 2026-04-12T12:00:00Z — verify with: date -u -r 1775995200
}

@test "blocks sub-cooldown actions at COOLDOWN_DAYS=7 (regression for #25)" {
  export COOLDOWN_DAYS=7
  run bash scripts/check-release-age.sh < tests/fixtures/check-release-age/nexus-mcp-160.tsv
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/check-release-age/nexus-mcp-160-cooldown-7.tsv
}

@test "passes everything at COOLDOWN_DAYS=0 (escape hatch)" {
  export COOLDOWN_DAYS=0
  run bash scripts/check-release-age.sh < tests/fixtures/check-release-age/nexus-mcp-160.tsv
  [ "$status" -eq 0 ]
  diff <(echo "$output") tests/fixtures/check-release-age/nexus-mcp-160-cooldown-0.tsv
}

@test "PyPI happy path returns pass for aged release" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "requests\t2.32.5\tpypi\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^requests$'\t'2\.32\.5$'\t'pypi$'\t'.+$'\t'[0-9]+$'\t'pass$'\t'$ ]]
}

@test "yanked PyPI release fails regardless of age" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "yanked-pkg\t1.0.0\tpypi\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^yanked-pkg$'\t'1\.0\.0$'\t'pypi$'\t'.+$'\t'[0-9]+$'\t'fail$'\t'yanked$ ]]
}

@test "missing fixture (simulates 404) produces error verdict" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "no-such-action/does-not-exist\t1.0.0\tactions\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^no-such-action/does-not-exist$'\t'1\.0\.0$'\t'actions$'\t'-$'\t'-$'\t'error$'\t'tier-1-404$ ]]
}

@test "npm happy path returns pass for aged release" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "lodash\t4.17.21\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^lodash$'\t'4\.17\.21$'\t'npm$'\t'.+$'\t'[0-9]+$'\t'pass$'\t'$ ]]
}

@test "npm scoped package name resolves its fixture" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "@types/node\t22.19.9\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^@types/node$'\t'22\.19\.9$'\t'npm$'\t'.+$'\t'[0-9]+$'\t'pass$'\t'$ ]]
}

@test "deprecated npm release fails regardless of age" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "deprecated-pkg\t1.0.0\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^deprecated-pkg$'\t'1\.0\.0$'\t'npm$'\t'.+$'\t'[0-9]+$'\t'fail$'\t'deprecated$ ]]
}

@test "missing npm fixture produces npm-404 error verdict" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "no-such-pkg\t9.9.9\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^no-such-pkg$'\t'9\.9\.9$'\t'npm$'\t'-$'\t'-$'\t'error$'\t'npm-404$ ]]
}

@test "npm release younger than COOLDOWN_DAYS fails" {
  # @types/node fixture publishedAt 2026-02-05; NOW_EPOCH is 2026-04-12, so a
  # very large cooldown forces the violation branch deterministically.
  export COOLDOWN_DAYS=999
  run bash -c 'printf "@types/node\t22.19.9\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^@types/node$'\t'22\.19\.9$'\t'npm$'\t'.+$'\t'[0-9]+$'\t'fail$'\t'$ ]]
}

@test "npm response missing publishedAt produces transient-failure" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "no-published-at\t1.0.0\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^no-published-at$'\t'1\.0\.0$'\t'npm$'\t'-$'\t'-$'\t'error$'\t'transient-failure$ ]]
}

@test "npm response with unparseable timestamp produces parse-failure" {
  export COOLDOWN_DAYS=7
  run bash -c 'printf "bad-timestamp\t1.0.0\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^bad-timestamp$'\t'1\.0\.0$'\t'npm$'\t'-$'\t'-$'\t'error$'\t'parse-failure$ ]]
}

@test "urlencode_segment percent-encodes scope separators" {
  run bash -c 'eval "$(sed -n "/^urlencode_segment()/,/^}/p" scripts/check-release-age.sh)"; urlencode_segment "@types/node"'
  [ "$status" -eq 0 ]
  [ "$output" = "%40types%2Fnode" ]
}

@test "urlencode_segment neutralises path traversal in a version string" {
  run bash -c 'eval "$(sed -n "/^urlencode_segment()/,/^}/p" scripts/check-release-age.sh)"; urlencode_segment "1.0.0/../../lodash/versions/4.17.21"'
  [ "$status" -eq 0 ]
  [[ "$output" != */* ]]
  [ "$output" = "1.0.0%2F..%2F..%2Flodash%2Fversions%2F4.17.21" ]
}

@test "urlencode_segment leaves unreserved characters alone" {
  run bash -c 'eval "$(sed -n "/^urlencode_segment()/,/^}/p" scripts/check-release-age.sh)"; urlencode_segment "lodash-4.17.21_x.y"'
  [ "$status" -eq 0 ]
  [ "$output" = "lodash-4.17.21_x.y" ]
}

@test "npm release exactly at COOLDOWN_DAYS passes (boundary is inclusive)" {
  # @types/node fixture publishedAt 2026-02-05T14:45:05Z against the pinned
  # NOW_EPOCH gives age_days == 65 exactly, so this pins the -ge boundary.
  export COOLDOWN_DAYS=65
  run bash -c 'printf "@types/node\t22.19.9\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^@types/node$'\t'22\.19\.9$'\t'npm$'\t'.+$'\t'65$'\t'pass$'\t'$ ]]
}

@test "npm release one day under COOLDOWN_DAYS fails" {
  export COOLDOWN_DAYS=66
  run bash -c 'printf "@types/node\t22.19.9\tnpm\n" | bash scripts/check-release-age.sh'
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^@types/node$'\t'22\.19\.9$'\t'npm$'\t'.+$'\t'65$'\t'fail$'\t'$ ]]
}

# --- docker (container image) release age ---------------------------------

docker_row() { printf '%s\t%s\tdocker\n' "$1" "$2" | bash scripts/check-release-age.sh; }

@test "docker newest platform wins and fraction is dropped" {
  export COOLDOWN_DAYS=10
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t2026-04-03T08:02:05Z\t9\tfail\t' ]
}

@test "docker tag-only reference passes when old enough" {
  export COOLDOWN_DAYS=7
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t2026-04-03T08:02:05Z\t9\tpass\t' ]
}

@test "docker digest is looked up in preference to tag" {
  export COOLDOWN_DAYS=7
  local dc="sha256:$(printf 'c%.0s' $(seq 64))"
  # Only the digest-keyed fixture is consulted; the tag fixture would give the same body,
  # so also prove the tag is not used by pointing at a tag that has no fixture.
  run docker_row python "no-such-tag@$dc"
  [ "$status" -eq 0 ]
  [ "$output" = "python"$'\t'"no-such-tag@$dc"$'\t'$'docker\t2026-04-03T08:02:05Z\t9\tpass\t' ]
}

@test "docker non-Hub registry single manifest" {
  export COOLDOWN_DAYS=7
  run docker_row ghcr.io/astral-sh/uv 0.9.0
  [ "$status" -eq 0 ]
  [ "$output" = $'ghcr.io/astral-sh/uv\t0.9.0\tdocker\t2026-04-10T00:00:00Z\t2\tfail\t' ]
}

@test "docker reproducible-build epoch timestamp is an error" {
  export COOLDOWN_DAYS=7
  run docker_row gcr.io/distroless/static nonroot
  [ "$status" -eq 0 ]
  [ "$output" = $'gcr.io/distroless/static\tnonroot\tdocker\t-\t-\terror\timplausible-timestamp' ]
}

@test "docker future timestamp is an error" {
  export COOLDOWN_DAYS=7
  run docker_row ghcr.io/example/future 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'ghcr.io/example/future\t1.0\tdocker\t-\t-\terror\timplausible-timestamp' ]
}

@test "docker epoch platform is an error even when a newer platform is valid" {
  # amd64 config is created=1970; arm64 is a valid 2026 date that would win the max.
  export COOLDOWN_DAYS=7
  run docker_row mixed 1.0
  [ "$status" -eq 0 ]
  [ "$output" = $'mixed\t1.0\tdocker\t-\t-\terror\timplausible-timestamp' ]
}

@test "docker missing manifest is docker-404" {
  export COOLDOWN_DAYS=7
  run docker_row python 9.9
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t9.9\tdocker\t-\t-\terror\tdocker-404' ]
}

@test "docker unresolved reference is an error without lookup" {
  export COOLDOWN_DAYS=7
  run docker_row '${BASE}' -
  [ "$status" -eq 0 ]
  [ "$output" = $'${BASE}\t-\tdocker\t-\t-\terror\tdocker-unresolved-reference' ]
}

@test "docker_registry_repo maps names" {
  export COOLDOWN_DAYS=7
  run bash -c 'CHECK_RELEASE_AGE_LIB=1 source scripts/check-release-age.sh
    for n in python docker.io/library/python bitnami/redis ghcr.io/a/b localhost:5000/x; do docker_registry_repo "$n"; done'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'registry-1.docker.io\tlibrary/python' ]
  [ "${lines[1]}" = $'registry-1.docker.io\tlibrary/python' ]
  [ "${lines[2]}" = $'registry-1.docker.io\tbitnami/redis' ]
  [ "${lines[3]}" = $'ghcr.io\ta/b' ]
  [ "${lines[4]}" = $'localhost:5000\tx' ]
}

# Live mode: PATH-stubbed curl, AGE_FIXTURE_DIR unset. Scenario in $DK_SCENARIO.
docker_live_setup() {
  unset AGE_FIXTURE_DIR
  export COOLDOWN_DAYS=7 AGE_RETRY_SLEEP=0
  export DK_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$DK_LOG"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
hfile= bfile= url= auth=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) shift; hfile="$1" ;;
    -o) shift; bfile="$1" ;;
    -w) shift ;;
    --proto|--proto-redir) shift; printf 'P: %s\n' "$1" >> "$DK_LOG" ;;
    -H) shift; printf 'H: %s\n' "$1" >> "$DK_LOG"
        [ "$1" = "Authorization: Bearer T" ] && auth=true ;;
    http*) url="$1"; printf 'URL: %s\n' "$1" >> "$DK_LOG" ;;
  esac
  shift
done
code=200; body='{}'; hdr=
cfg='{"config":{"digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
case "$url" in
  https://auth.example/token*) body='{"token":"T"}' ;;
  */blobs/*)
    if [ "$DK_SCENARIO" = nocreated ]; then body='{}'; else body='{"created":"2026-04-03T00:00:00Z"}'; fi ;;
  */manifests/*)
    case "$DK_SCENARIO" in
      bearer) if [ "$auth" = true ]; then body="$cfg"; else code=401
        hdr='WWW-Authenticate: Bearer realm="https://auth.example/token",service="reg",scope="repository:library/python:pull"'; fi ;;
      authfail) code=401
        hdr='WWW-Authenticate: Bearer realm="https://auth.example/token",service="reg",scope="repository:library/python:pull"' ;;
      httprealm) code=401
        hdr='WWW-Authenticate: Bearer realm="http://auth.example/token",service="reg",scope="repository:library/python:pull"' ;;
      rate) code=429 ;;
      fivexx) code=503 ;;
      badjson) body='not json' ;;
      nocreated) body="$cfg" ;;
    esac ;;
esac
printf 'HTTP/2 %s\r\n%s\r\n\r\n' "$code" "$hdr" > "$hfile"
printf '%s' "$body" > "$bfile"
printf '%s' "$code"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "docker live: bearer challenge, anonymous token, then success" {
  docker_live_setup; export DK_SCENARIO=bearer
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^python$'\t'3\.13-slim$'\t'docker$'\t'2026-04-03T00:00:00Z$'\t'[0-9]+$'\t'pass$'\t'$ ]]
  grep -q '^URL: https://auth.example/token.*service=reg' "$DK_LOG"
  grep -q 'scope=repository:library/python:pull' "$DK_LOG"
  grep -q '^H: Authorization: Bearer T$' "$DK_LOG"
}

@test "docker live: 401 after token is docker-auth-required" {
  docker_live_setup; export DK_SCENARIO=authfail
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t-\t-\terror\tdocker-auth-required' ]
}

@test "docker live: 429 is docker-rate-limited" {
  docker_live_setup; export DK_SCENARIO=rate
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t-\t-\terror\tdocker-rate-limited' ]
}

@test "docker live: repeated 5xx is transient-failure after one retry" {
  docker_live_setup; export DK_SCENARIO=fivexx
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t-\t-\terror\ttransient-failure' ]
  [ "$(grep -c '^URL: .*/manifests/' "$DK_LOG")" -eq 2 ]
}

@test "docker live: malformed manifest JSON is parse-failure" {
  docker_live_setup; export DK_SCENARIO=badjson
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t-\t-\terror\tparse-failure' ]
}

@test "docker live: config without created is parse-failure" {
  docker_live_setup; export DK_SCENARIO=nocreated
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t-\t-\terror\tparse-failure' ]
}

@test "docker live: non-https auth realm is rejected without a request" {
  docker_live_setup; export DK_SCENARIO=httprealm
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$output" = $'python\t3.13-slim\tdocker\t-\t-\terror\tdocker-auth-required' ]
  ! grep -q 'http://auth.example' "$DK_LOG"
}

@test "docker live: registry requests are restricted to https" {
  docker_live_setup; export DK_SCENARIO=bearer
  run docker_row python 3.13-slim
  [ "$status" -eq 0 ]
  [ "$(grep -c '^P: =https$' "$DK_LOG")" -ge 4 ]
}
