#!/usr/bin/env bats

# Helper: asserts a fixture is fully disqualified. Both modes must emit
# zero output. Using this for every disqualifier test is mandatory —
# checking only --mode=deps cannot distinguish a disqualified file from
# a clean comment-only file (both emit no rows; only cleared-paths
# differs).
assert_disqualified() {
  local fixture="$1"
  run bash scripts/pyproject-bump-extract.sh --mode=deps < "$fixture"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < "$fixture"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Helper: asserts a fixture is a clean bump. Emits the expected single TSV
# row in deps mode and the expected path in cleared-paths mode.
assert_clean_bump() {
  local fixture="$1" expected_row="$2" expected_path="$3"
  run bash scripts/pyproject-bump-extract.sh --mode=deps < "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_row" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < "$fixture"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_path" ]
}

@test "missing --mode exits 2 with stderr message" {
  run bash -c 'printf "" | bash scripts/pyproject-bump-extract.sh'
  [ "$status" -eq 2 ]
  [[ "$output" == *"--mode=deps or --mode=cleared-paths required"* ]]
}

@test "unknown --mode exits 2 with stderr message" {
  run bash -c 'printf "" | bash scripts/pyproject-bump-extract.sh --mode=banana'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown"* ]] || [[ "$output" == *"banana"* ]]
}

@test "--mode specified twice exits 2" {
  run bash -c 'printf "" | bash scripts/pyproject-bump-extract.sh --mode=deps --mode=cleared-paths'
  [ "$status" -eq 2 ]
}

@test "empty input with --mode=deps exits 0 with empty stdout" {
  run bash -c 'printf "" | bash scripts/pyproject-bump-extract.sh --mode=deps'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty input with --mode=cleared-paths exits 0 with empty stdout" {
  run bash -c 'printf "" | bash scripts/pyproject-bump-extract.sh --mode=cleared-paths'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed input with --mode=deps exits 2" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/not-a-diff.txt
  [ "$status" -eq 2 ]
  [[ "$output" == *"input is not a unified diff"* ]]
}

@test "malformed input with --mode=cleared-paths exits 2" {
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/not-a-diff.txt
  [ "$status" -eq 2 ]
  [[ "$output" == *"input is not a unified diff"* ]]
}

@test "PEP 621 [project] dependencies bump — deps mode emits row" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/pep621-dependencies-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "ruff	0.15.13	pypi" ]
}

@test "PEP 621 [project] dependencies bump — cleared-paths mode emits path" {
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/pep621-dependencies-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "pyproject.toml" ]
}

@test "PEP 621 [project.optional-dependencies] bump" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/pep621-optional-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "httpx	0.28.1	pypi" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/pep621-optional-bump.diff
  [ "$output" = "pyproject.toml" ]
}

@test "PEP 735 [dependency-groups] bump" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/pep735-group-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "pytest	8.4.0	pypi" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/pep735-group-bump.diff
  [ "$output" = "pyproject.toml" ]
}

@test "uv [tool.uv] constraint-dependencies bump" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/uv-constraint-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "urllib3	2.5.0	pypi" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/uv-constraint-bump.diff
  [ "$output" = "pyproject.toml" ]
}

@test "uv [tool.uv] override-dependencies bump" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/uv-override-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "certifi	2024.2.2	pypi" ]
}

@test "Poetry main key=value bump" {
  assert_clean_bump tests/fixtures/pyproject-bump-extract/poetry-main-bump.diff $'requests\t2.32\tpypi' "pyproject.toml"
}

@test "Poetry python constraint change disqualifies" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/poetry-python-constraint-change.diff
}

@test "Poetry inline-table version-only bump" {
  assert_clean_bump tests/fixtures/pyproject-bump-extract/poetry-inline-table-bump.diff $'ruff\t0.15.13\tpypi' "pyproject.toml"
}

@test "Poetry inline-table extras change disqualifies" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/poetry-inline-extras-change.diff
}

@test "Poetry [tool.poetry.group.dev.dependencies] bump" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/poetry-group-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "pytest	8.4.0	pypi" ]
}

@test "Poetry legacy [tool.poetry.dev-dependencies] bump" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/poetry-dev-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "black	24.2.0	pypi" ]
}

@test "Subdir pyproject.toml bump emits subdir path" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/subdir-pyproject-bump.diff
  [ "$status" -eq 0 ]
  [ "$output" = "fastapi	0.111.0	pypi" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/subdir-pyproject-bump.diff
  [ "$output" = "services/api/pyproject.toml" ]
}

@test "Multi-file: cleared subdir + disqualified root in same diff" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/multi-file-mixed.diff
  [ "$status" -eq 0 ]
  [ "$output" = "fastapi	0.111.0	pypi" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/multi-file-mixed.diff
  [ "$output" = "services/api/pyproject.toml" ]
}

@test "Disqualify: PEP 621 new-dep addition" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-add-dep.diff
}

@test "Disqualify: PEP 621 dep removal (unmatched -)" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-remove-dep.diff
}

@test "Disqualify: PEP 621 marker change" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-marker-change.diff
}

@test "Disqualify: PEP 621 extras change" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-extras-change.diff
}

@test "Disqualify: PEP 621 version + marker both change (skeleton mismatch)" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-version-plus-marker-change.diff
}

@test "Disqualify: PEP 621 version + extras both change (skeleton mismatch)" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-version-plus-extras-change.diff
}

@test "Disqualify: PEP 621 unmatched removal followed by context (pending lifetime)" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-unmatched-removal.diff
}

@test "Disqualify: adding a new extras key in [project.optional-dependencies] (structural)" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-add-extras-key.diff
}

@test "Disqualify: adding the dependencies = [ array to [project] (structural)" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/pep621-add-dependencies-array.diff
}

@test "Disqualify: build-system edit" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/build-system-edit.diff
}

@test "Disqualify: mid-array hunk with no header context" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/mid-array-no-context.diff
}

@test "Disqualify: unrecognized table" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/unrecognized-table-edit.diff
}

@test "Disqualify: mixed bump + addition in same file" {
  assert_disqualified tests/fixtures/pyproject-bump-extract/mixed-bump-and-add.diff
}
