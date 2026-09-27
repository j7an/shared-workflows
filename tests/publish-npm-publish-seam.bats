bats_require_minimum_version 1.5.0
#!/usr/bin/env bats
# publish-npm-publish-seam.bats — execute the publish step's run block against
# a stub npm on PATH.
#
# WHY THIS FILE EXISTS. The publish step skips `npm publish` when the version
# is already on the registry, so a re-run after a later job failed can finish.
# Skipping on name@version alone would let a hand-published tarball from other
# source pass silently and the GitHub Release would attach different bytes.
# These cases pin that the skip requires a matching dist.integrity.
#
# EVERY negated assertion carries `|| return 1`. Bash exempts `! cmd` from
# errexit, so a bare mid-body negation is a silent no-op under bats.

WF=".github/workflows/publish-npm.yml"
STEP="Publish to npm"

# sha512 of FIXTURE_BYTES, derived with Python hashlib rather than openssl so
# the expected value does not share the step's implementation.
FIXTURE_BYTES='fixture tarball bytes'
FIXTURE_INTEGRITY='sha512-tGkquRVyKSGx17hbG575VLtf5JYk7MjOcXxRMazBLMIy90/alr3NzLU/3LH75ybQESKP0uJg0Kzjwg6sGUNOyg=='

extract_step_block() {
  awk -v want="      - name: $1" '
    $0 == want { found=1; next }
    found && /^        run: \|$/ { inrun=1; next }
    inrun && /^      - / { exit }
    inrun { sub(/^          /, ""); print }
  ' "$WF"
}

setup() {
  TEST_TMP=$(mktemp -d)
  WORKDIR="$TEST_TMP/work"
  mkdir -p "$WORKDIR" "$TEST_TMP/bin"
  printf '%s\n' "$FIXTURE_BYTES" > "$WORKDIR/perms-1.0.0.tgz"
  export PACKAGE="perms" VERSION="1.0.0"
  export NPM_LOG="$TEST_TMP/npm.log"
  : > "$NPM_LOG"
  # `npm view` prints $REGISTRY_INTEGRITY, or fails like an E404 when unset.
  cat > "$TEST_TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$NPM_LOG"
if [ "$1" = view ]; then
  [ -n "${REGISTRY_INTEGRITY:-}" ] || { echo "npm error code E404" >&2; exit 1; }
  echo "$REGISTRY_INTEGRITY"
fi
EOF
  chmod +x "$TEST_TMP/bin/npm"
  export PATH="$TEST_TMP/bin:$PATH"
}

teardown() {
  rm -rf "$TEST_TMP"
}

run_publish_step() {
  local script="$TEST_TMP/publish.sh"
  { echo 'set -e'; extract_step_block "$STEP"; } > "$script"
  ( cd "$WORKDIR" && bash "$script" )
}

@test "the publish step block extracts non-empty" {
  block="$(extract_step_block "$STEP")"
  [[ "$block" == *"npm publish"* ]]
}

@test "an absent version is published" {
  unset REGISTRY_INTEGRITY
  run run_publish_step
  [ "$status" -eq 0 ]
  grep -qx 'publish ./perms-1.0.0.tgz' "$NPM_LOG"
}

@test "an existing version with matching integrity skips publish" {
  export REGISTRY_INTEGRITY="$FIXTURE_INTEGRITY"
  run run_publish_step
  [ "$status" -eq 0 ]
  [[ "$output" == *"matching integrity; skipping npm publish."* ]] || return 1
  ! grep -q '^publish' "$NPM_LOG" || return 1
}

@test "an existing version with different integrity fails without publishing" {
  export REGISTRY_INTEGRITY="sha512-someoneElsesTarball=="
  run run_publish_step
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]] || return 1
  [[ "$output" == *"sha512-someoneElsesTarball=="* ]] || return 1
  [[ "$output" == *"$FIXTURE_INTEGRITY"* ]] || return 1
  ! grep -q '^publish' "$NPM_LOG" || return 1
}
