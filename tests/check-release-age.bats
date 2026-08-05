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
