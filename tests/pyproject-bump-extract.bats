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

run_pyproject_deps() {
  run bash -c 'bash scripts/pyproject-bump-extract.sh --mode=deps' <<< "$1"
}

run_pyproject_cleared() {
  run bash -c 'bash scripts/pyproject-bump-extract.sh --mode=cleared-paths' <<< "$1"
}

assert_disqualified_diff() {
  local diff="$1"

  run_pyproject_deps "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run_pyproject_cleared "$diff"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

assert_clean_bump_diff() {
  local diff="$1" expected_row="$2" expected_path="$3"

  run_pyproject_deps "$diff"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_row" ]

  run_pyproject_cleared "$diff"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_path" ]
}

# Build a minimal PEP 621 [project] dependencies bump diff. One - and one + line.
# Args: $1 = minus body inside quotes (e.g. "ruff>=0.15.12")
#       $2 = plus body inside quotes (e.g. "ruff>=0.15.13")
# Both args are inserted verbatim between the leading 4-space indent and the
# trailing comma. Hunk header is fixed at @@ -10,7 +10,7 @@.
pep621_deps_diff() {
  printf '%s\n' \
    'diff --git a/pyproject.toml b/pyproject.toml' \
    '--- a/pyproject.toml' \
    '+++ b/pyproject.toml' \
    '@@ -10,7 +10,7 @@' \
    ' [project]' \
    ' dependencies = [' \
    "-    $1," \
    "+    $2," \
    ' ]'
}

# Build a minimal Poetry [tool.poetry.dependencies] keyval diff. One - and one +.
# Args: $1 = minus body (e.g. 'pkg = "==1.0"')
#       $2 = plus body (e.g. 'pkg = "^2.0"')
poetry_main_kv_diff() {
  printf '%s\n' \
    'diff --git a/pyproject.toml b/pyproject.toml' \
    '--- a/pyproject.toml' \
    '+++ b/pyproject.toml' \
    '@@ -1,2 +1,2 @@' \
    ' [tool.poetry.dependencies]' \
    "-$1" \
    "+$2"
}

# Build a minimal Poetry [tool.poetry.dependencies] inline-table diff.
# Args: $1 = minus body (e.g. 'pkg = { version = "==1.0", source = "internal" }')
#       $2 = plus body
poetry_inline_diff() {
  printf '%s\n' \
    'diff --git a/pyproject.toml b/pyproject.toml' \
    '--- a/pyproject.toml' \
    '+++ b/pyproject.toml' \
    '@@ -1,2 +1,2 @@' \
    ' [tool.poetry.dependencies]' \
    "-$1" \
    "+$2"
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
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,7 +10,7 @@
 [tool.poetry.dependencies]
-python = "^3.11"
+python = "^3.12"
 requests = "^2.32"
DIFF
)"
}

@test "Poetry inline-table version-only bump" {
  assert_clean_bump tests/fixtures/pyproject-bump-extract/poetry-inline-table-bump.diff $'ruff\t0.15.13\tpypi' "pyproject.toml"
}

@test "Poetry inline-table extras change disqualifies" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,7 +10,7 @@
 [tool.poetry.dependencies]
 python = "^3.11"
-ruff = { version = "^0.15.13", extras = ["server"] }
+ruff = { version = "^0.15.13", extras = ["server", "lsp"] }
DIFF
)"
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
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,6 +10,7 @@
 [project]
 dependencies = [
     "ruff>=0.15.13",
+    "newpkg>=1.0.0",
 ]
DIFF
)"
}

@test "Disqualify: PEP 621 dep removal (unmatched -)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,7 +10,6 @@
 [project]
 dependencies = [
     "ruff>=0.15.13",
-    "oldpkg>=1.0.0",
 ]
DIFF
)"
}

@test "Disqualify: PEP 621 marker change" {
  assert_disqualified_diff "$(pep621_deps_diff '"foo>=1.2; python_version < \"3.11\""' '"foo>=1.2; python_version < \"3.12\""')"
}

@test "Disqualify: PEP 621 extras change" {
  assert_disqualified_diff "$(pep621_deps_diff '"httpx[http2]>=0.28.0"' '"httpx[http2,brotli]>=0.28.0"')"
}

@test "Disqualify: PEP 621 version + marker both change (skeleton mismatch)" {
  assert_disqualified_diff "$(pep621_deps_diff '"foo>=1.1; python_version < '"'"'3.11'"'"'"' '"foo>=1.2; python_version < '"'"'3.12'"'"'"')"
}

@test "Disqualify: PEP 621 version + extras both change (skeleton mismatch)" {
  assert_disqualified_diff "$(pep621_deps_diff '"httpx[http2]>=0.28.0"' '"httpx[http2,brotli]>=0.28.1"')"
}

@test "Disqualify: PEP 621 unmatched removal followed by context (pending lifetime)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,7 +10,6 @@
 [project]
 dependencies = [
-    "oldpkg>=1.0.0",
     "ruff>=0.15.13",
 ]
DIFF
)"
}

@test "Disqualify: adding a new extras key in [project.optional-dependencies] (structural)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,6 +10,9 @@
 [project.optional-dependencies]
 server = [
     "httpx>=0.28.1",
 ]
+lsp = [
+    "lsprotocol>=2025.0.0",
+]
DIFF
)"
}

@test "Disqualify: adding the dependencies = [ array to [project] (structural)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -5,6 +5,9 @@
 [project]
 name = "foo"
 version = "0.1.0"
+dependencies = [
+    "ruff>=0.15.13",
+]
DIFF
)"
}

@test "Disqualify: build-system edit" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,6 +1,6 @@
 [build-system]
 requires = [
-    "hatchling>=1.20.0",
+    "hatchling>=1.21.0",
 ]
 build-backend = "hatchling.build"
DIFF
)"
}

@test "Disqualify: mid-array hunk with no header context" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -100,4 +100,4 @@
-    "ruff>=0.15.12",
+    "ruff>=0.15.13",
     "httpx>=0.27.0",
 ]
DIFF
)"
}

@test "Disqualify: unrecognized table" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -50,7 +50,7 @@
 [tool.foo]
-bar = "old"
+bar = "new"
DIFF
)"
}

@test "Disqualify: mixed bump + addition in same file" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
index 1111111..2222222 100644
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -10,7 +10,8 @@
 [project]
 dependencies = [
-    "ruff>=0.15.12",
+    "ruff>=0.15.13",
+    "newpkg>=1.0.0",
     "httpx>=0.27.0",
 ]
DIFF
)"
}

@test "Comment-only churn clears path with zero deps" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/comment-only-churn.diff
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/comment-only-churn.diff
  [ "$status" -eq 0 ]; [ "$output" = "pyproject.toml" ]
}

@test "Whitespace-only churn in unrelated table clears path" {
  run bash scripts/pyproject-bump-extract.sh --mode=deps < tests/fixtures/pyproject-bump-extract/whitespace-churn-other-table.diff
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash scripts/pyproject-bump-extract.sh --mode=cleared-paths < tests/fixtures/pyproject-bump-extract/whitespace-churn-other-table.diff
  [ "$status" -eq 0 ]; [ "$output" = "pyproject.toml" ]
}

@test "Positive: package name with digits (urllib3)" {
  DIFF="$(pep621_deps_diff '"urllib3>=2.4.0"' '"urllib3>=2.5.0"')"
  run_pyproject_deps "$DIFF"
  [ "$status" -eq 0 ]
  [ "$output" = "urllib3	2.5.0	pypi" ]
  run_pyproject_cleared "$DIFF"
  [ "$output" = "pyproject.toml" ]
}

@test "Positive: bump with unchanged marker preserved on both sides" {
  DIFF="$(pep621_deps_diff '"foo>=1.1; python_version < \"3.12\""' '"foo>=1.2; python_version < \"3.12\""')"
  run_pyproject_deps "$DIFF"
  [ "$status" -eq 0 ]
  [ "$output" = "foo	1.2	pypi" ]
  run_pyproject_cleared "$DIFF"
  [ "$output" = "pyproject.toml" ]
}

@test "Positive: PEP 440 post-release version" {
  DIFF="$(pep621_deps_diff '"pkg>=1.0.0"' '"pkg>=1.0.0.post1"')"
  run_pyproject_deps "$DIFF"
  [ "$status" -eq 0 ]
  [ "$output" = "pkg	1.0.0.post1	pypi" ]
  run_pyproject_cleared "$DIFF"
  [ "$output" = "pyproject.toml" ]
}

@test "Disqualify: PEP 508 compound spec (>=X,<Y)" {
  assert_disqualified_diff "$(pep621_deps_diff '"ruff>=0.15.12,<0.16"' '"ruff>=0.15.13,<0.16"')"
}

@test "Disqualify: PEP 508 upper-bound change (<X)" {
  assert_disqualified_diff "$(pep621_deps_diff '"foo<3.0"' '"foo<4.0"')"
}

@test "Disqualify: PEP 508 not-equal change (!=X)" {
  assert_disqualified_diff "$(pep621_deps_diff '"foo!=1.2.0"' '"foo!=1.3.0"')"
}

@test "Disqualify: poetry wildcard (\"*\")" {
  assert_disqualified_diff "$(poetry_main_kv_diff 'foo = "1.0.0"' 'foo = "*"')"
}

@test "Disqualify: current_key leak — keywords array after dependencies (Bug 1)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,10 +1,10 @@
 [project]
 dependencies = [
   "ruff>=0.1",
 ]
 keywords = [
-  "docs>=1.0",
+  "docs>=2.0",
 ]
DIFF
)"
}

@test "Disqualify: current_key leak — uv dev-dependencies after constraint-dependencies (Bug 1)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,10 +1,10 @@
 [tool.uv]
 constraint-dependencies = [
   "ruff>=0.1",
 ]
 dev-dependencies = [
-  "docs>=1.0",
+  "docs>=2.0",
 ]
DIFF
)"
}

@test "Disqualify: poetry inline-table subversion does not match version (Bug 2)" {
  assert_disqualified_diff "$(poetry_inline_diff 'pkg = { subversion = "1.0.0", source = "internal" }' 'pkg = { subversion = "2.0.0", source = "internal" }')"
}

@test "Disqualify: PEP 508 operator change (== to >=) is constraint broadening (Bug 3)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,5 +1,5 @@
 [project]
 dependencies = [
-  "foo==1.0",
+  "foo>=2.0",
 ]
DIFF
)"
}

@test "Disqualify: poetry keyval operator change (== to ^) is constraint broadening (Bug 3)" {
  assert_disqualified_diff "$(poetry_main_kv_diff 'pkg = "==1.0"' 'pkg = "^2.0"')"
}

@test "Disqualify: poetry inline-table operator change (== to ^) is constraint broadening (Bug 3)" {
  assert_disqualified_diff "$(poetry_inline_diff 'pkg = { version = "==1.0", source = "internal" }' 'pkg = { version = "^2.0", source = "internal" }')"
}

@test "Disqualify: poetry inline-table whitespace around version= changed (Bug 4)" {
  assert_disqualified_diff "$(poetry_inline_diff 'ruff = { version = "^0.15.12", extras = ["server"] }' 'ruff = { version="^0.15.13", extras = ["server"] }')"
}

@test "Disqualify: malformed PEP 508 bare version (no operator) (Bug 5)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,4 +1,4 @@
 [project]
 dependencies = [
-    "foo 1.0",
+    "foo 2.0",
 ]
DIFF
)"
}

@test "Disqualify: PEP 508 entries after a closing ] inherit no dependency context (Bug 1b)" {
  assert_disqualified_diff "$(cat <<'DIFF'
diff --git a/pyproject.toml b/pyproject.toml
--- a/pyproject.toml
+++ b/pyproject.toml
@@ -1,8 +1,8 @@
 [project]
 dependencies = [
   "ruff>=0.1",
 ]
-  "docs>=1.0",
+  "docs>=2.0",
 ]
DIFF
)"
}
