#!/usr/bin/env bats
# release-workflow-contract.bats - static checks for release.yml provenance

YAML=".github/workflows/release.yml"

update_step() {
  awk '
    /^      - name: Update floating major and minor tags$/ { flag=1; next }
    flag && /^      - name: / { exit }
    flag { print }
  ' "$YAML"
}

assert_contains() {
  local text="$1"
  local expected="$2"
  [[ "$text" == *"$expected"* ]]
}

assert_lacks() {
  local text="$1"
  local forbidden="$2"
  [[ "$text" != *"$forbidden"* ]]
}

@test "release.yml uses API-managed lightweight floating tags" {
  step="$(update_step)"
  assert_contains "$step" 'REPO="${GITHUB_REPOSITORY}"'
  assert_contains "$step" 'gh api "repos/${REPO}/git/ref/tags/${TAG}"'
  assert_contains "$step" 'gh api "repos/${REPO}/git/tags/${TAG_SHA}"'
  assert_contains "$step" 'TARGET_SHA='
  assert_contains "$step" 'update_floating_ref "$MINOR" "$TARGET_SHA"'
  assert_contains "$step" 'update_floating_ref "$MAJOR" "$TARGET_SHA"'
}

@test "release.yml moves existing floating refs with force true and create fallback" {
  step="$(update_step)"
  assert_contains "$step" 'gh api -X PATCH "repos/${REPO}/git/refs/tags/${ref_name}"'
  assert_contains "$step" '-F force=true'
  assert_contains "$step" '>/dev/null 2>"$err_file"'
  assert_contains "$step" 'gh api -X POST "repos/${REPO}/git/refs"'
  assert_contains "$step" '-f ref="refs/tags/${ref_name}"'
  assert_contains "$step" '-f sha="$target_sha"'
}

@test "release.yml reports target commit verification without gating on it" {
  step="$(update_step)"
  assert_contains "$step" 'TARGET_VERIFIED='
  assert_contains "$step" 'Target commit verification'
  assert_lacks "$step" 'TARGET_VERIFIED" != "true"'
}

@test "release.yml does not use local tag commands or annotated tag object creation" {
  body="$(grep -v '^[[:space:]]*#' "$YAML")"
  compact="$(printf '%s' "$body" | tr '\n' ' ')"
  tag_creation_lines=$(printf '%s\n' "$body" | grep -E 'git[[:space:]]+tag' | grep -vE 'git[[:space:]]+tag[[:space:]]+-l([[:space:]]|$)' || true)
  if printf '%s' "$tag_creation_lines" | grep -qE '(^|[[:space:]])(--annotate|-s|--sign|-[[:alnum:]]*a[[:alnum:]]*)([[:space:]]|$)'; then
    false
  fi
  assert_lacks "$body" 'git push origin "$MINOR"'
  assert_lacks "$body" 'git push origin "$MAJOR"'
  if printf '%s' "$compact" | grep -qE 'gh api[^;|&]*((-X[[:space:]]*POST|--method[ =]POST)[^;|&]*git/tags|git/tags[^;|&]*(-X[[:space:]]*POST|--method[ =]POST))'; then
    false
  fi
  assert_lacks "$body" 'git config user.name'
  assert_lacks "$body" 'git config user.email'
}
