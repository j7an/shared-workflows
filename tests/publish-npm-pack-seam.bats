bats_require_minimum_version 1.5.0
#!/usr/bin/env bats
# publish-npm-pack-seam.bats — execute the pack step's run block against
# shell stubs.
#
# WHY THIS FILE EXISTS. publish-npm-workflow-contract.bats is grep-over-YAML:
# it pins the SHAPE of the pack step and nothing about what its bash DOES. The
# provenance check, the metadata-shape handling and the leak-timing fix are all
# behavior, and all three are silently deletable without this file.
#
# No packer is involved. PACK_COMMAND is plain shell, so every case is bash,
# and nothing here touches npm, pnpm or the network.
#
# --separate-stderr throughout. The step writes its ::error:: diagnostics to
# STDOUT, as GitHub Actions workflow commands conventionally are, so the
# diagnostic assertions target $output and the empty-stream assertions target
# $stderr — the reverse of the scripts/*.sh test files in this suite.
#
# EVERY negated assertion carries `|| return 1`. Bash exempts `! cmd` from
# errexit, so a bare mid-body negation is a silent no-op under bats.

WF=".github/workflows/publish-npm.yml"
STEP="Pack once and stage the tarball"

# npm's real failure envelope, verified against npm 12.0.2: a failing prepack
# exits 7 and writes {"error":{"code","summary","detail"}} to stdout. There is
# no "message" key, so these stubs are modeled on the packer, not on the code.
NPM_ERROR_ENVELOPE='{"error":{"code":7,"summary":"command failed","detail":"sh -c exit 7"}}'

extract_step_block() {
  awk -v want="      - name: $1" '
    $0 == want { found=1; next }
    found && /^        run: \|$/ { inrun=1; next }
    inrun && /^      - / { exit }
    inrun { sub(/^          /, ""); print }
  ' "$WF"
}

setup() {
  REPO_ROOT="$PWD"
  TEST_TMP=$(mktemp -d)
  export RUNNER_TEMP="$TEST_TMP/runner"
  mkdir -p "$RUNNER_TEMP"
  WORKDIR="$TEST_TMP/work"
  mkdir -p "$WORKDIR/packages/perms"
  export PACKAGE_DIR="packages/perms"
  export PACK_CONTENTS_SCRIPT=""
}

teardown() {
  rm -rf "$TEST_TMP"
}

run_pack_step() {
  local script="$TEST_TMP/pack.sh"
  { echo 'set -e'; extract_step_block "$STEP"; } > "$script"
  ( cd "$WORKDIR" && bash "$script" )
}

# --- the seam itself -------------------------------------------------------

@test "the pack step block extracts non-empty" {
  block="$(extract_step_block "$STEP")"
  [ -n "$block" ]
  [[ "$block" == *"EXPECTED_TARBALL"* ]]
}

# --- happy paths and metadata shapes ---------------------------------------

@test "happy path stages the produced tarball" {
  export PACK_COMMAND='printf "{\"filename\":\"good-1.0.0.tgz\"}" && touch good-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -f "$RUNNER_TEMP/dist/good-1.0.0.tgz" ]
  # Moved, not copied: the package dir must not still hold a publishable tarball.
  [ ! -f "$WORKDIR/packages/perms/good-1.0.0.tgz" ]
}

@test "npm array metadata shape yields the filename" {
  export PACK_COMMAND='printf "[{\"filename\":\"arr-1.0.0.tgz\"}]" && touch arr-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -f "$RUNNER_TEMP/dist/arr-1.0.0.tgz" ]
}

@test "npm keyed-object metadata shape yields the filename" {
  export PACK_COMMAND='printf "{\"pkg\":{\"filename\":\"key-1.0.0.tgz\"}}" && touch key-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ -f "$RUNNER_TEMP/dist/key-1.0.0.tgz" ]
}

# --- provenance ------------------------------------------------------------

@test "a stale tarball is refused even though the count is one" {
  touch "$WORKDIR/packages/perms/stale-0.0.1.tgz"
  export PACK_COMMAND='printf "{\"filename\":\"fresh-1.0.0.tgz\"}"'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to publish a stale tarball"* ]] || return 1
  [[ "$output" == *"stale-0.0.1.tgz"* ]] || return 1
  [[ "$output" == *"fresh-1.0.0.tgz"* ]] || return 1
  [ ! -f "$RUNNER_TEMP/dist/stale-0.0.1.tgz" ]
  [ -z "$stderr" ]
}

@test "a stale tarball left in the staging dir is cleared before packing" {
  mkdir -p "$RUNNER_TEMP/dist"
  touch "$RUNNER_TEMP/dist/previous-0.0.1.tgz"
  export PACK_COMMAND='printf "{\"filename\":\"good-1.0.0.tgz\"}" && touch good-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  [ ! -f "$RUNNER_TEMP/dist/previous-0.0.1.tgz" ]
  [ -f "$RUNNER_TEMP/dist/good-1.0.0.tgz" ]
  [ -z "$stderr" ]
}

@test "no tarball fails the count check" {
  export PACK_COMMAND='printf "{\"filename\":\"x-1.0.0.tgz\"}"'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"Expected exactly one tarball in packages/perms, found 0"* ]] || return 1
  [ -z "$stderr" ]
}

@test "two tarballs fail the count check" {
  export PACK_COMMAND='printf "{\"filename\":\"a.tgz\"}" && touch a.tgz b.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"Expected exactly one tarball in packages/perms, found 2"* ]] || return 1
  [ ! -f "$RUNNER_TEMP/dist/a.tgz" ]
  [ ! -f "$RUNNER_TEMP/dist/b.tgz" ]
  [ -z "$stderr" ]
}

# --- unusable or failing pack metadata -------------------------------------

@test "malformed metadata fails before staging" {
  export PACK_COMMAND='printf "not json" && touch x.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot prove which artifact this run produced"* ]] || return 1
  [ ! -f "$RUNNER_TEMP/dist/x.tgz" ]
  [ -z "$stderr" ]
}

@test "metadata without a filename fails before staging" {
  export PACK_COMMAND='printf "{}" && touch x.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot prove which artifact this run produced"* ]] || return 1
  [ ! -f "$RUNNER_TEMP/dist/x.tgz" ]
  [ -z "$stderr" ]
}

@test "empty metadata fails before staging" {
  export PACK_COMMAND='true && touch x.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot prove which artifact this run produced"* ]] || return 1
  [ ! -f "$RUNNER_TEMP/dist/x.tgz" ]
  [ -z "$stderr" ]
}

@test "an error object with exit 0 is caught" {
  export PACK_COMMAND="printf '%s' '$NPM_ERROR_ENVELOPE'"
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"pack command reported an error"* ]] || return 1
  [[ "$output" == *"::error::command failed: sh -c exit 7"* ]] || return 1
  [ -z "$stderr" ]
}

@test "a non-zero packer surfaces npm's summary and detail" {
  export PACK_COMMAND="printf '%s' '$NPM_ERROR_ENVELOPE'; exit 7"
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"pack command failed in packages/perms"* ]] || return 1
  [[ "$output" == *"::error::command failed: sh -c exit 7"* ]] || return 1
  [ -z "$stderr" ]
}

@test "an unrecognized error envelope still surfaces the raw metadata" {
  # Nothing may be silently swallowed: with no summary/detail/message the whole
  # envelope is dumped, so a caller never has to reproduce the failure locally.
  export PACK_COMMAND='printf "{\"error\":{\"code\":7}}"; exit 7'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *'::error::{"error":{"code":7}}'* ]] || return 1
  [ -z "$stderr" ]
}

@test "a packer reporting only message is still surfaced" {
  # Covers the defensive third element of the jq fallback list.
  export PACK_COMMAND='printf "{\"error\":{\"message\":\"needs install\"}}"; exit 1'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::needs install"* ]] || return 1
  [ -z "$stderr" ]
}

# --- the sealed-pack.json leak regression ----------------------------------

@test "pack metadata is absent from the package dir DURING packing" {
  # The regression test for the sealed-pack.json leak. The stub records what
  # it sees at pack time; the assertion is about that observation, not about
  # where the file ends up.
  export PACK_COMMAND='ls pack.json > "$RUNNER_TEMP/seen" 2>&1 || true; printf "{\"filename\":\"t-1.0.0.tgz\"}" && touch t-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  # Non-empty proves the stub ran, so the negation below cannot pass vacuously.
  [ -s "$RUNNER_TEMP/seen" ]
  ! grep -q '^pack.json$' "$RUNNER_TEMP/seen" || return 1
  [ -f "$WORKDIR/packages/perms/pack.json" ]
  [ -z "$stderr" ]
}

# --- pack-contents-script argument -----------------------------------------

@test "pack-contents-script receives a repository-root-relative path" {
  cat > "$WORKDIR/echo-arg.sh" <<'SH'
printf '%s' "$1" > "$RUNNER_TEMP/arg"
SH
  export PACK_CONTENTS_SCRIPT="echo-arg.sh"
  export PACK_COMMAND='printf "{\"filename\":\"r-1.0.0.tgz\"}" && touch r-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  [ "$(cat "$RUNNER_TEMP/arg")" = "packages/perms/pack.json" ]
  [ -z "$stderr" ]
}

@test "a root package receives the literal pack.json, as before" {
  export PACKAGE_DIR="."
  cat > "$WORKDIR/echo-arg.sh" <<'SH'
printf '%s' "$1" > "$RUNNER_TEMP/arg"
SH
  export PACK_CONTENTS_SCRIPT="echo-arg.sh"
  export PACK_COMMAND='printf "{\"filename\":\"root-1.0.0.tgz\"}" && touch root-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -eq 0 ]
  [ "$(cat "$RUNNER_TEMP/arg")" = "pack.json" ]
  [ -f "$RUNNER_TEMP/dist/root-1.0.0.tgz" ]
  [ -z "$stderr" ]
}

@test "a failing pack-contents-script fails the step" {
  cat > "$WORKDIR/reject.sh" <<'SH'
echo "contents rejected"
exit 3
SH
  export PACK_CONTENTS_SCRIPT="reject.sh"
  export PACK_COMMAND='printf "{\"filename\":\"c-1.0.0.tgz\"}" && touch c-1.0.0.tgz'
  run --separate-stderr run_pack_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"contents rejected"* ]] || return 1
  [ ! -f "$RUNNER_TEMP/dist/c-1.0.0.tgz" ]
  [ -z "$stderr" ]
}
