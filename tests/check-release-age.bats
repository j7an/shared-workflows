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
