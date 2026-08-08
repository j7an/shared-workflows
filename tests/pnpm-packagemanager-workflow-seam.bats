bats_require_minimum_version 1.5.0
#!/usr/bin/env bats
# pnpm-packagemanager-workflow-seam.bats - execute the run blocks of
# pnpm-packagemanager-update.yml against stubbed `curl` and `gh`.
#
# WHY THIS FILE EXISTS. pnpm-packagemanager-workflow-contract.bats is entirely
# grep-over-YAML: it pins the SHAPE of the workflow and nothing about what the
# bash inside `Resolve and update` actually DOES. The whole-branch review proved
# the gap by mutating the workflow five times; every mutation left the suite
# green. Each mutation now has a test here that reddens on it:
#
#   1. --expect="$INTEGRITY" -> --expect=""      "a mismatched dist.integrity ..."
#   2. CUR_ALGO=... -> CUR_ALGO="sha512"         "a sha224 pin is rewritten ..."
#   3. if [ -z "$CUR_SUF" ] -> [ -n ... ]        "a sha224 pin ..." + "a suffixless pin ..."
#   4. -f state=success -> -f state=failure      "the evidence status posts success ..."
#   5. registry.npmjs.org/pnpm -> ...-EVIL       every Resolve-step test (stub map miss)
#
# The workflow is driven, not reimplemented: each step's `run:` body is lifted
# verbatim out of the YAML, de-indented, and executed. A step renamed or
# re-indented makes extract_step_block emit nothing and the tests fail rather
# than silently passing against an empty script.
#
# EVERY negated assertion here carries `|| return 1`. Bash exempts `! cmd` from
# errexit, so a bare mid-body `! grep ...` is a silent no-op under bats - the
# same defect class as this project's bare-`[[ ]]` rule. That applies even to a
# negation that happens to be the last line of its test today, because appending
# one line below it would silently kill it.

WF=".github/workflows/pnpm-packagemanager-update.yml"
MFX="tests/fixtures/packagemanager-bump/manifests"
SFX="tests/fixtures/pnpm-packagemanager-seam"
# The tarball fixtures are the two 512-byte payloads already committed for
# packagemanager-integrity.bats; reusing them means the digests below are the
# ones that file already documents and derives.
PAYLOAD="tests/fixtures/packagemanager-integrity/payload.bin"

# ---------------------------------------------------------------------------
# Fixture digests. Derived on 2026-08-07 with tools independent of the code
# under test, agreeing pairwise:
#
#   shasum -a 224 tests/fixtures/packagemanager-integrity/payload.bin
#   openssl dgst -sha224 tests/fixtures/packagemanager-integrity/payload.bin
#     -> PAYLOAD_SHA224
#   shasum -a 512 .../payload.bin ; openssl dgst -sha512 .../payload.bin
#     -> PAYLOAD_SHA512
#
# The SRI claims embedded in the seam packuments were derived as:
#
#   openssl dgst -sha512 -binary .../payload.bin       | openssl base64 -A
#     -> packument-good.json .dist.integrity          (MATCHES payload.bin)
#   openssl dgst -sha512 -binary .../payload-other.bin | openssl base64 -A
#     -> packument-integrity-mismatch.json            (does NOT match)
#
# These are fixture literals the suite defines for itself - inputs, not claims
# about the world. No pnpm version named here is read from anywhere but these
# fixtures.
# ---------------------------------------------------------------------------
PAYLOAD_SHA224="b8060ccc82d40c576156f7ca0333e4389e410df027d2fb8f764fa603"
PAYLOAD_SHA512="edb9bed721aa6a5f6fbc6619d3a3c2be3d043043f05a9aebc7b1197a2aa9c49a57d5ddd4674c1785785088d9f1ff42c797a02adc9b817a139a50970da6c99524"

# The packument URL the workflow is expected to fetch. Deliberately the only
# entry the curl stub map is seeded with, so mutation 5 (any other registry
# path) becomes a resolve failure rather than a silent pass.
PACKUMENT_URL="https://registry.npmjs.org/pnpm"
TARBALL_URL="https://registry.npmjs.org/pnpm/-/pnpm-9.15.9.tgz"

setup() {
  REPO_ROOT="$PWD"
  TEST_TMP=$(mktemp -d)
  STUB_BIN="$TEST_TMP/bin"
  WORKDIR="$TEST_TMP/work"
  mkdir -p "$STUB_BIN" "$WORKDIR"

  export RUNNER_TEMP="$TEST_TMP/runner"
  mkdir -p "$RUNNER_TEMP"
  export GITHUB_OUTPUT="$TEST_TMP/out"
  : > "$GITHUB_OUTPUT"

  export CURL_ARGS="$TEST_TMP/curl_args"
  export CURL_MAP="$TEST_TMP/curl_map"
  export GH_ARGS="$TEST_TMP/gh_args"
  : > "$CURL_ARGS"
  : > "$CURL_MAP"
  : > "$GH_ARGS"

  write_curl_stub
  write_gh_stub
}

teardown() {
  rm -rf "$TEST_TMP"
}

# --- extraction -------------------------------------------------------------

# Lift one step's `run:` body out of the YAML as plain bash. The 10-space strip
# is the same normalization check-inline-sync.sh applies to the inline copies.
extract_step_block() {
  awk -v step="      - name: $1" '
    $0 == step                       { in_step = 1; next }
    in_step && /^        run: \|$/   { in_run = 1; next }
    in_run && /^      - name: /      { exit }
    in_run                           { print }
  ' "$REPO_ROOT/$WF" | sed -E 's/^          //'
}

# A step whose body failed to extract must not read as a passing no-op.
write_step_script() {
  local name="$1" dest="$2"
  extract_step_block "$name" > "$dest"
  [ -s "$dest" ] || {
    echo "extract_step_block found no run body for step: $name"
    return 1
  }
}

# --- stubs ------------------------------------------------------------------

map_add() { printf '%s\t%s\n' "$1" "$2" >> "$CURL_MAP"; }

# curl serving fixtures. Any URL absent from CURL_MAP fails the way a real
# unresolvable host does, which is what makes an altered registry URL loud.
write_curl_stub() {
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_ARGS"
url=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)         out="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -*)         shift ;;
    *)          url="$1"; shift ;;
  esac
done
src=""
while IFS=$'\t' read -r map_url map_file; do
  [ "$map_url" = "$url" ] || continue
  src="$map_file"
done < "$CURL_MAP"
if [ -z "$src" ]; then
  echo "curl: (6) Could not resolve host for $url" >&2
  exit 6
fi
cp "$src" "$out"
STUB
  chmod +x "$STUB_BIN/curl"
}

# gh recording its argv one element per line, so tests can assert on exact
# arguments with `grep -qx` rather than on a re-joined command string.
write_gh_stub() {
  cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GH_ARGS"
if [ -n "${GH_STDOUT:-}" ]; then
  printf '%s\n' "$GH_STDOUT"
fi
exit "${GH_EXIT:-0}"
STUB
  chmod +x "$STUB_BIN/gh"
}

# --- drivers ----------------------------------------------------------------

# Copy a manifest fixture into the fake checkout under the given repo-relative
# path (the workflow reads it with a path relative to the workspace root).
place_manifest() {
  local fixture="$1" dest="${2:-package.json}"
  mkdir -p "$WORKDIR/$(dirname "$dest")"
  cp "$REPO_ROOT/$fixture" "$WORKDIR/$dest"
}

run_resolve() {
  local f="$TEST_TMP/resolve.sh"
  write_step_script "Resolve and update" "$f" || return 1
  PATH="$STUB_BIN:$PATH" run bash -c 'cd "$1" && bash "$2"' bash "$WORKDIR" "$f"
}

run_step() {
  local f="$TEST_TMP/step.sh"
  write_step_script "$1" "$f" || return 1
  PATH="$STUB_BIN:$PATH" run bash "$f"
}

# --- Resolve and update: the happy path ------------------------------------

@test "a sha224 pin is rewritten in place with a sha224 suffix over the verified bytes" {
  # Binds mutations 2 (CUR_ALGO forced to sha512), 3 (suffix branch inverted)
  # and 5 (registry URL). The expected suffix body is payload.bin's sha224 -
  # NOT its sha512 - because the pin declares sha224 and the workflow must
  # preserve the declared algorithm while VERIFYING with the claim's sha512.
  place_manifest "$MFX/hashed.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  map_add "$TARBALL_URL" "$REPO_ROOT/$PAYLOAD"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  grep -qx "target=9.15.9" "$GITHUB_OUTPUT"
  grep -qx "current=9.15.0" "$GITHUB_OUTPUT"
  grep -qx "select_mode=normal" "$GITHUB_OUTPUT"
  grep -qx "manifest_path=package.json" "$GITHUB_OUTPUT"
  grep -qx "new_value=9.15.9+sha224.${PAYLOAD_SHA224}" "$GITHUB_OUTPUT"
  grep -q "\"pnpm@9.15.9+sha224.${PAYLOAD_SHA224}\"" "$WORKDIR/package.json"
  # The algorithm must not have been upgraded to the digest we verified with.
  ! grep -q "$PAYLOAD_SHA512" "$WORKDIR/package.json" || return 1
  # Exactly the documented registry endpoint was fetched.
  grep -qx "$PACKUMENT_URL" "$CURL_ARGS"
}

@test "a suffixless pin is rewritten to a bare version and fetches no tarball" {
  # The other half of mutation 3: inverting the branch sends a suffixless pin
  # into the integrity path with an empty --algo, which fails.
  place_manifest "$MFX/plain.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  map_add "$TARBALL_URL" "$REPO_ROOT/$PAYLOAD"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  grep -qx "new_value=9.15.9" "$GITHUB_OUTPUT"
  grep -q '"pnpm@9.15.9"' "$WORKDIR/package.json"
  # No suffix was invented for a pin that never had one.
  ! grep -q 'pnpm@9.15.9+' "$WORKDIR/package.json" || return 1
  ! grep -qx "$TARBALL_URL" "$CURL_ARGS" || return 1
}

@test "the rewrite is confined to the packageManager value" {
  place_manifest "$MFX/plain.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  grep -q '"lodash": "\^4.17.21"' "$WORKDIR/package.json"
  grep -q '"version": "1.0.0"' "$WORKDIR/package.json"
}

@test "nothing newer in the major writes skip=true and leaves the manifest alone" {
  place_manifest "$MFX/hashed.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-nothing-newer.json"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  grep -qx "skip=true" "$GITHUB_OUTPUT"
  ! grep -q "^new_value=" "$GITHUB_OUTPUT" || return 1
  grep -q '"pnpm@9.15.0+sha224.953c8233' "$WORKDIR/package.json"
}

# --- Resolve and update: integrity ----------------------------------------

@test "a mismatched dist.integrity fails the step and leaves the manifest untouched" {
  # Binds mutation 1. With --expect="" the byte check never runs, the digest of
  # whatever arrived is written, and this test goes green - so it must be red.
  place_manifest "$MFX/hashed.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-integrity-mismatch.json"
  map_add "$TARBALL_URL" "$REPO_ROOT/$PAYLOAD"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  # Assert the REASON, not just the exit code: an integrity mismatch and a
  # fetch failure both exit 1 through different branches.
  [ "${output#*::error::integrity-failure: downloaded bytes do not match dist.integrity}" != "$output" ]
  grep -q '"pnpm@9.15.0+sha224.953c8233' "$WORKDIR/package.json"
  ! grep -q "^new_value=" "$GITHUB_OUTPUT" || return 1
}

@test "a packument with no dist.integrity emits a workflow warning annotation" {
  place_manifest "$MFX/hashed.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-no-integrity.json"
  map_add "$TARBALL_URL" "$REPO_ROOT/$PAYLOAD"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  # A plain-stderr warning does not surface in the checks UI; the annotation does.
  [ "${output#*::warning::the npm registry published no dist.integrity for pnpm 9.15.9}" != "$output" ]
  grep -qx "new_value=9.15.9+sha224.${PAYLOAD_SHA224}" "$GITHUB_OUTPUT"
}

# --- Resolve and update: tarball host allowlist -----------------------------

@test "a tarball on a lookalike host is refused before any fetch" {
  # dist.tarball and dist.integrity come from the same document, so verifying
  # one against the other proves nothing about origin. The host must be checked.
  place_manifest "$MFX/hashed.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-foreign-tarball.json"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::tarball URL for pnpm 9.15.9 is not hosted on registry.npmjs.org}" != "$output" ]
  ! grep -q "evil.example" "$CURL_ARGS" || return 1
  grep -q '"pnpm@9.15.0+sha224.953c8233' "$WORKDIR/package.json"
}

@test "the host comparison is exact, so a userinfo lookalike is refused too" {
  # This binds the EXACTNESS of the `!=`, which is the entire guard. The
  # authority of https://registry.npmjs.org@evil.example/... is the whole
  # string "registry.npmjs.org@evil.example", which is simply not equal to
  # "registry.npmjs.org" - so no userinfo stripping is needed, and an earlier
  # draft's strip only ever WIDENED what was accepted. Relaxing the comparison
  # to a substring or suffix match reddens this test and the lookalike-host
  # test above together.
  place_manifest "$MFX/hashed.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-userinfo-tarball.json"
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::tarball URL for pnpm 9.15.9 is not hosted on registry.npmjs.org}" != "$output" ]
  ! grep -q "evil.example" "$CURL_ARGS" || return 1
}

# --- Resolve and update: registry fetch ------------------------------------

@test "a registry fetch failure fails the step rather than reading as current" {
  place_manifest "$MFX/hashed.json"
  # CURL_MAP left empty: every URL is unresolvable.
  export INPUT_MANIFEST_PATH="package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::registry fetch failed}" != "$output" ]
  ! grep -q "skip=true" "$GITHUB_OUTPUT" || return 1
}

# --- Resolve and update: manifest_path ------------------------------------

@test "./package.json is normalized so the post-PR verify comparison can match" {
  # The GitHub API reports "package.json"; an unnormalized "./package.json"
  # would make the verify step fail AFTER the pull request already exists.
  place_manifest "$MFX/plain.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  export INPUT_MANIFEST_PATH="./package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  grep -qx "manifest_path=package.json" "$GITHUB_OUTPUT"
  ! grep -q "manifest_path=./package.json" "$GITHUB_OUTPUT" || return 1
}

@test "a path that normalizes to an absolute one is refused after normalization" {
  # `.//etc/passwd` begins with '.', not '/', and contains no '..', so it clears
  # a guard placed only on the raw input - and then the leading-"./" strip turns
  # it into the absolute `/etc/passwd`. Without the post-normalization re-check
  # the step read that file and published `manifest_path=/etc/passwd`, which
  # feeds `add-paths:` and the verify comparison.
  place_manifest "$MFX/plain.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  export INPUT_MANIFEST_PATH=".//etc/passwd"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::manifest_path must be a relative path}" != "$output" ]
  # The rejection must land BEFORE the value is published, not merely before
  # the pull request is opened.
  ! grep -q "^manifest_path=/" "$GITHUB_OUTPUT" || return 1
  [ ! -s "$CURL_ARGS" ]
}

@test "a nested manifest path keeps its directory through normalization" {
  place_manifest "$MFX/plain.json" "packages/app/package.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  export INPUT_MANIFEST_PATH="./packages/app/package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -eq 0 ]
  grep -qx "manifest_path=packages/app/package.json" "$GITHUB_OUTPUT"
  grep -q '"pnpm@9.15.9"' "$WORKDIR/packages/app/package.json"
}

@test "a manifest_path carrying a newline is refused before anything runs" {
  # The value flows into create-pull-request's newline-separated add-paths,
  # where a newline would silently widen the commit's path restriction.
  place_manifest "$MFX/plain.json"
  map_add "$PACKUMENT_URL" "$REPO_ROOT/$SFX/packument-good.json"
  export INPUT_MANIFEST_PATH="package.json
other.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::manifest_path must not contain newlines}" != "$output" ]
  [ ! -s "$CURL_ARGS" ]
}

@test "a manifest_path carrying a carriage return is refused" {
  place_manifest "$MFX/plain.json"
  export INPUT_MANIFEST_PATH=$'package.json\rother.json'
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::manifest_path must not contain newlines}" != "$output" ]
  [ ! -s "$CURL_ARGS" ]
}

@test "an absolute manifest_path is refused" {
  place_manifest "$MFX/plain.json"
  export INPUT_MANIFEST_PATH="/etc/package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::manifest_path must be a relative path}" != "$output" ]
  [ ! -s "$CURL_ARGS" ]
}

@test "a traversing manifest_path is refused" {
  place_manifest "$MFX/plain.json"
  export INPUT_MANIFEST_PATH="../package.json"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::manifest_path must be a relative path}" != "$output" ]
  [ ! -s "$CURL_ARGS" ]
}

@test "a manifest_path that normalizes to nothing is refused" {
  place_manifest "$MFX/plain.json"
  export INPUT_MANIFEST_PATH="./"
  export INPUT_MIN_AGE_DAYS=5

  run_resolve
  [ "$status" -ne 0 ]
  [ "${output#*::error::manifest_path must not be empty}" != "$output" ]
  [ ! -s "$CURL_ARGS" ]
}

# --- Verify the pull request touches only the manifest ----------------------

@test "the verify step accepts the API's normalized single-file reply" {
  export GH_TOKEN="t"
  export GH_REPO="octo/example"
  export PR="7"
  export MANIFEST="package.json"
  export GH_STDOUT="package.json"

  run_step "Verify the pull request touches only the manifest"
  [ "$status" -eq 0 ]
  grep -qx "repos/octo/example/pulls/7/files" "$GH_ARGS"
}

@test "the verify step fails when the pull request touches anything else" {
  export GH_TOKEN="t"
  export GH_REPO="octo/example"
  export PR="7"
  export MANIFEST="package.json"
  export GH_STDOUT="package.json
pnpm-lock.yaml"

  run_step "Verify the pull request touches only the manifest"
  [ "$status" -ne 0 ]
  [ "${output#*::error::pull request touches unexpected paths}" != "$output" ]
}

# --- Post the pnpm packageManager evidence status ---------------------------

@test "the evidence status posts success with its own context and a run URL" {
  # Binds mutation 4: -f state=failure would fail the first assertion.
  export GH_TOKEN="t"
  export GH_REPO="octo/example"
  export PR="7"
  export HEAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export TARGET="9.15.9"
  export SELECT_MODE="normal"
  export MIN_AGE_DAYS="5"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="octo/example"
  export GITHUB_RUN_ID="123"

  run_step "Post the pnpm packageManager evidence status"
  [ "$status" -eq 0 ]
  grep -qx "state=success" "$GH_ARGS"
  grep -qx "context=pnpm-packageManager / evidence" "$GH_ARGS"
  grep -qx "repos/octo/example/statuses/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$GH_ARGS"
  grep -qx "target_url=https://github.com/octo/example/actions/runs/123" "$GH_ARGS"
  grep -q "^description=pnpm 9.15.9: exact published version, not deprecated, 5d+ old" "$GH_ARGS"
}

@test "a bypass run says so in the description and stays inside 140 characters" {
  export GH_TOKEN="t"
  export GH_REPO="octo/example"
  export PR="7"
  export HEAD_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  export TARGET="9.15.9"
  export SELECT_MODE="bypass"
  export MIN_AGE_DAYS="5"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="octo/example"
  export GITHUB_RUN_ID="123"

  run_step "Post the pnpm packageManager evidence status"
  [ "$status" -eq 0 ]
  grep -qx "state=success" "$GH_ARGS"
  desc=$(grep "^description=" "$GH_ARGS")
  desc="${desc#description=}"
  [ "${desc#*Cooldown bypassed}" != "$desc" ]
  [ "${#desc}" -le 140 ]
}

@test "a pull request with no reported head SHA fails instead of skipping quietly" {
  # The old guard was `pull-request-head-sha != ''`, so this state produced a
  # green job carrying a pull request with no evidence status at all.
  export GH_TOKEN="t"
  export GH_REPO="octo/example"
  export PR="7"
  export HEAD_SHA=""
  export TARGET="9.15.9"
  export SELECT_MODE="normal"
  export MIN_AGE_DAYS="5"
  export GITHUB_SERVER_URL="https://github.com"
  export GITHUB_REPOSITORY="octo/example"
  export GITHUB_RUN_ID="123"

  run_step "Post the pnpm packageManager evidence status"
  [ "$status" -ne 0 ]
  [ "${output#*::error::pull request #7 exists but create-pull-request reported no head SHA}" != "$output" ]
  # No status was posted to a guessed commit.
  [ ! -s "$GH_ARGS" ]
}

# --- Compose pull request body ---------------------------------------------

@test "registry deprecation prose cannot render HTML in the pull request body" {
  # Blockquoting stops Markdown but not HTML: `> > <img src=x>` renders a live
  # image tag and leaks a viewer's IP and User-Agent to whoever the prose names.
  cp "$REPO_ROOT/$SFX/deprecation-html.txt" "$RUNNER_TEMP/deprecation.txt"
  export CURRENT="9.15.0"
  export TARGET="9.15.9"
  export SELECT_MODE="bypass"
  export DEPRECATION_FILE="$RUNNER_TEMP/deprecation.txt"
  export MIN_AGE_DAYS="5"
  export USE_FALLBACK_CAVEAT="false"

  run_step "Compose pull request body"
  [ "$status" -eq 0 ]
  body="$RUNNER_TEMP/pr-body.md"
  ! grep -q '<img' "$body" || return 1
  ! grep -q '<details' "$body" || return 1
  grep -q '&lt;img src=' "$body"
  grep -q '&lt;details' "$body"
  # Quoting is still per line, so a multi-line notice cannot escape the block.
  ! grep -v '^> > ' "$body" | grep -q 'Hidden from a collapsed reviewer' || return 1
}

@test "the fallback caveat appears only on the GITHUB_TOKEN path" {
  export CURRENT="9.15.0"
  export TARGET="9.15.9"
  export SELECT_MODE="normal"
  export DEPRECATION_FILE=""
  export MIN_AGE_DAYS="5"

  export USE_FALLBACK_CAVEAT="true"
  run_step "Compose pull request body"
  [ "$status" -eq 0 ]
  grep -q "recursion guard" "$RUNNER_TEMP/pr-body.md"

  export USE_FALLBACK_CAVEAT="false"
  run_step "Compose pull request body"
  [ "$status" -eq 0 ]
  ! grep -q "recursion guard" "$RUNNER_TEMP/pr-body.md" || return 1
}

# --- Preflight auth ---------------------------------------------------------

@test "half-configured App auth fails loudly instead of degrading to GITHUB_TOKEN" {
  export APP_ID="123456"
  export APP_PRIVATE_KEY=""

  run_step "Preflight auth"
  [ "$status" -ne 0 ]
  [ "${output#*::error::App auth half-configured}" != "$output" ]
  ! grep -q "auth_mode=" "$GITHUB_OUTPUT" || return 1
}

@test "no App configuration at all is a legitimate fallback" {
  export APP_ID=""
  export APP_PRIVATE_KEY=""

  run_step "Preflight auth"
  [ "$status" -eq 0 ]
  grep -qx "auth_mode=fallback" "$GITHUB_OUTPUT"
  grep -qx "use_fallback_caveat=true" "$GITHUB_OUTPUT"
}

@test "fully configured App auth selects app mode and drops the caveat" {
  export APP_ID="123456"
  export APP_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----
notarealkey
-----END PRIVATE KEY-----"

  run_step "Preflight auth"
  [ "$status" -eq 0 ]
  grep -qx "auth_mode=app" "$GITHUB_OUTPUT"
  grep -qx "use_fallback_caveat=false" "$GITHUB_OUTPUT"
  # The secret must never reach an output file or the step log.
  ! grep -q "notarealkey" "$GITHUB_OUTPUT" || return 1
  ! grep -q "notarealkey" <<< "$output" || return 1
}
