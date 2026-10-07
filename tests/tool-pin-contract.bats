#!/usr/bin/env bats

load helpers/action-pin-assertions

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

WORKFLOW=.github/workflows/tool-pin-bump.yml
# One "key file" line per file each updater matrix entry pins.
MATRIX_PINS='.jobs.bump.strategy.matrix.include[] | .key as $k | .files[] | $k + " " + .'

@test "version inputs are exact and tracked" {
  local tracked inputs path key type value
  tracked=$(yq "$MATRIX_PINS" "$WORKFLOW")
  # node-version floats within a major on purpose.
  inputs=$(yq ea -N '((.jobs[]? | select(.uses) | .with // {}), (.jobs[]?.steps[]? | .with // {}), (.runs.steps[]? | .with // {})) | to_entries[] | select((.key == "version" or (.key | test("-version$"))) and .key != "node-version") | [filename, .key, (.value | tag), .value] | @tsv' .github/workflows/*.yml actions/*/action.yml)
  while IFS=$'\t' read -r path key type value; do
    [[ $type == '!!str' && $value =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$path: $key must be an exact version string"; return 1; }
    grep -qxF "$key $path" <<< "$tracked" || { echo "$path: $key is not tracked by the updater"; return 1; }
  done <<< "$inputs"
}

@test "tool-installing actions set their version" {
  local pair offenders
  for pair in zizmorcore/zizmor-action:version astral-sh/setup-uv:version bats-core/bats-action:bats-version; do
    offenders=$(ACTION=${pair%%:*} KEY=${pair#*:} yq ea -N '((.jobs[]? | select(.uses)), .jobs[]?.steps[]?, .runs.steps[]?) | select(((.uses // "") | test("^" + strenv(ACTION) + "@")) and ((.with // {}) | has(strenv(KEY)) | not)) | filename' .github/workflows/*.yml actions/*/action.yml)
    [ -z "$offenders" ] || { echo "$offenders: ${pair%%:*} must set ${pair#*:}"; return 1; }
  done
}

@test "matrix entries match a pin in every file" {
  local pins key file
  pins=$(yq "$MATRIX_PINS" "$WORKFLOW")
  # ponytail: keys are interpolated unescaped; escape them if a key ever holds regex metacharacters.
  while read -r key file; do
    grep -qE "^[[:space:]]+$key: \"[0-9]+\.[0-9]+\.[0-9]+\"[[:space:]]*\$" "$file" || { echo "$file: no exact $key pin"; return 1; }
  done <<< "$pins"
}

# Values are compared as compact JSON: yq's own == is neither deep nor type-strict.
@test "minimum age equals Dependabot cooldown" {
  local age cooldown
  age=$(yq -o=json -I=0 '.env.MIN_AGE_DAYS' "$WORKFLOW")
  cooldown=$(yq -o=json -I=0 '[.updates[] | select(.["package-ecosystem"] == "github-actions")][0].cooldown["default-days"]' .github/dependabot.yml)
  [ "$age" = "$cooldown" ]
}

@test "workflow permissions are minimal" {
  [ "$(yq -o=json -I=0 '.permissions' "$WORKFLOW")" = '{}' ]
  [ "$(yq -o=json -I=0 '.jobs.bump.permissions' "$WORKFLOW")" = '{"contents":"read"}' ]
  [ "$(yq -o=json -I=0 '[.jobs.bump.steps[] | select(.id == "app-token")][0].with["permission-workflows"]' "$WORKFLOW")" = '"write"' ]
}

@test "bump step fails on API errors" {
  # bump must use explicit bash for pipefail.
  [ "$(yq -o=json -I=0 '[.jobs.bump.steps[] | select(.id == "bump")][0].shell' "$WORKFLOW")" = '"bash"' ]
}

@test "PR branch is fixed per tool" {
  local pr token
  pr='[.jobs.bump.steps[] | select((.uses // "") | test("^peter-evans/create-pull-request@"))][0].with'
  [ "$(yq -o=json -I=0 "$pr.branch" "$WORKFLOW")" = '"deps/tool-pin-${{ matrix.name }}"' ]
  [ "$(yq -o=json -I=0 "$pr[\"sign-commits\"]" "$WORKFLOW")" = true ]
  [ "$(yq -o=json -I=0 "$pr[\"delete-branch\"]" "$WORKFLOW")" = true ]
  token=$(yq "$pr.token // \"\"" "$WORKFLOW")
  # PR must use only the App token.
  [[ $token == *steps.app-token.outputs.token* && $token != *github.token* ]]
}

@test "actions are SHA-pinned" {
  local workflow
  workflow=$(cat .github/workflows/tool-pin-bump.yml)
  assert_action_pin "$workflow" "step-security/harden-runner"
  assert_action_pin "$workflow" "actions/checkout"
  assert_action_pin "$workflow" "actions/create-github-app-token"
  assert_action_pin "$workflow" "peter-evans/create-pull-request"
}


prepare_bump_step() {
  local root="$PWD"
  export API_FIXTURES="$BATS_TEST_TMPDIR/api"
  mkdir -p "$API_FIXTURES" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/scripts"
  cp scripts/bump-tool-pin.sh "$BATS_TEST_TMPDIR/scripts/"
  yq '.jobs.bump.steps[] | select(.id == "bump") | .run' "$WORKFLOW" > "$BATS_TEST_TMPDIR/bump.sh"
  export OLD_REF NEW_REF
  OLD_REF=$(printf '%040d' 1)
  NEW_REF=$(printf '%040d' 2)
  local file
  for file in security-scan security; do
    sed -E "s#(zizmorcore/zizmor-action@)[0-9a-f]+#\1$OLD_REF#; s@version: \"[0-9]+[.][0-9]+[.][0-9]+\"@version: \"1.0.0\"@" "$root/.github/workflows/$file.yml" > "$BATS_TEST_TMPDIR/$file.yml"
  done
  printf 'latest digest\n2.0.0 digest\n' > "$API_FIXTURES/$OLD_REF"
  printf 'latest digest\n2.0.0 digest\n3.0.0 digest\n' > "$API_FIXTURES/$NEW_REF"
  cat > "$API_FIXTURES/releases" <<'JSON'
[{"tag_name":"v3.0.0","published_at":"2020-01-01T00:00:00Z"},{"tag_name":"2.0.0","published_at":"2020-01-01T00:00:00Z"}]
JSON
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$API_FIXTURES/calls"
case "$*" in
  *'/releases?per_page=100') cat "$API_FIXTURES/releases" ;;
  *'Accept: application/vnd.github.raw+json'*'/contents/support/versions?ref='*)
    ref=${*: -1}
    cat "$API_FIXTURES/${ref##*ref=}" ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" REPO=zizmorcore/zizmor KEY=version MIN_AGE_DAYS=5
  export FILES='security-scan.yml security.yml' GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : > "$GITHUB_OUTPUT"
  cd "$BATS_TEST_TMPDIR"
}

@test "zizmor excludes aged releases unsupported by the pinned action" {
  prepare_bump_step
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  grep -q '^new=2.0.0$' "$GITHUB_OUTPUT"
  grep -q 'version: "2.0.0"' security-scan.yml
  grep -q 'version: "2.0.0"' security.yml
}

@test "updating zizmor action refs admits newly supported releases" {
  prepare_bump_step
  sed "s/$OLD_REF/$NEW_REF/" security.yml > updated.yml
  cp updated.yml security.yml
  cp security.yml security-scan.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  grep -q '^new=3.0.0$' "$GITHUB_OUTPUT"
}

@test "different zizmor action refs intersect supported releases" {
  prepare_bump_step
  sed "s/$OLD_REF/$NEW_REF/" security.yml > updated.yml
  cp updated.yml security.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  grep -q '^new=2.0.0$' "$GITHUB_OUTPUT"
  grep -q "support/versions[?]ref=$OLD_REF" "$API_FIXTURES/calls"
  grep -q "support/versions[?]ref=$NEW_REF" "$API_FIXTURES/calls"
}

@test "zizmor support fetch failure precedes edits and outputs" {
  prepare_bump_step
  rm "$API_FIXTURES/$OLD_REF"
  cp security-scan.yml before-scan.yml
  cp security.yml before.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -ne 0 ]
  cmp security.yml before.yml
  cmp security-scan.yml before-scan.yml
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "zizmor rejects unpinned action refs before fetching support" {
  prepare_bump_step
  sed "s/$OLD_REF/main/" security.yml > updated.yml
  cp updated.yml security.yml
  cp security.yml before.yml
  run bash -e -o pipefail bump.sh
  [ "$status" -ne 0 ]
  cmp security.yml before.yml
  [ ! -s "$GITHUB_OUTPUT" ]
  ! grep -q 'support/versions' "$API_FIXTURES/calls"
}

@test "non-zizmor release selection is unaffected by action support" {
  prepare_bump_step
  export REPO=astral-sh/uv
  run bash -e -o pipefail bump.sh
  [ "$status" -eq 0 ]
  grep -q '^new=3.0.0$' "$GITHUB_OUTPUT"
  ! grep -q 'support/versions' "$API_FIXTURES/calls"
}

@test "README documents intentional tool floats and their controls" {
  local text pattern
  text=$(awk '/^### Intentional floats[[:space:]]*$/ { found = 1; next } found && /^## / { exit } found' .github/workflows/README.md)
  [ -n "$text" ] || { echo 'missing intentional floats note'; return 1; }
  for pattern in 'Node.*major' 'Trivy.*action.*default' 'diff-cover.*range' 'diff-cover.*lower.bound' 'pnpm.*integrity'; do
    grep -qiE "$pattern" <<< "$text" || { echo "missing float policy: $pattern"; return 1; }
  done
}
