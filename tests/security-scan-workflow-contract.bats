#!/usr/bin/env bats
# security-scan-workflow-contract.bats - static contract tests for the
# reusable security scanning workflow.

YAML=".github/workflows/security-scan.yml"
README=".github/workflows/README.md"

assert_eq() {
  if [ "$1" != "$2" ]; then
    printf 'expected:\n%s\nactual:\n%s\n' "$2" "$1"
    return 1
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) return 0 ;;
    *)
      printf 'expected text to contain:\n%s\n' "$2"
      return 1
      ;;
  esac
}

assert_lacks() {
  case "$1" in
    *"$2"*)
      printf 'expected text not to contain:\n%s\n' "$2"
      return 1
      ;;
    *) return 0 ;;
  esac
}

assert_action_pin() {
  matches=$(printf '%s\n' "$1" | awk -v target="$2" '
    {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+uses:[[:space:]]*/, "", line)
      sub(/^[[:space:]]*uses:[[:space:]]*/, "", line)

      separator = index(line, " # ")
      if (separator == 0) {
        next
      }

      ref = substr(line, 1, separator - 1)
      comment = substr(line, separator + 3)
      if (index(ref, target "@") != 1) {
        next
      }

      sha = substr(ref, length(target) + 2)
      if (sha ~ /^[0-9a-f]{40}$/ && comment ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
        count++
      }
    }
    END { print count + 0 }
  ')

  if [ "$matches" -ne 1 ]; then
    printf 'expected exactly one semantic action pin for:\n%s\n' "$2"
    return 1
  fi
}

@test "action pin helper accepts Dependabot SHA and version bumps" {
  block=$'      - name: Perform CodeQL analysis\n        uses: github/codeql-action/analyze@1111111111111111111111111111111111111111 # v4.99.0'
  assert_action_pin "$block" "github/codeql-action/analyze"
}

@test "action pin helper rejects malformed pins" {
  block=$'      - name: Perform CodeQL analysis\n        uses: github/codeql-action/analyze@v4.99.0 # v4.99.0'
  if assert_action_pin "$block" "github/codeql-action/analyze"; then
    echo "expected non-SHA action ref to fail"
    return 1
  fi

  block=$'      - name: Perform CodeQL analysis\n        uses: github/codeql-action/analyze@1111111111111111111111111111111111111111'
  if assert_action_pin "$block" "github/codeql-action/analyze"; then
    echo "expected missing version comment to fail"
    return 1
  fi
}

@test "action pin helper requires an exact dotted target match" {
  block=$'    uses: google/osv-scanner-action/Xgithub/workflows/osv-scanner-reusableXyml@1111111111111111111111111111111111111111 # v2.99.0'
  if assert_action_pin "$block" "google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml"; then
    echo "expected exact dotted target match"
    return 1
  fi
}

on_block() {
  awk '
    /^on:$/ { flag=1; print; next }
    flag && /^[^[:space:]][^:]*:/ { exit }
    flag { print }
  ' "$YAML"
}

on_trigger_keys() {
  on_block | awk '
    /^  [A-Za-z0-9_-]+:$/ {
      sub(/^  /, "", $0);
      sub(/:$/, "", $0);
      print
    }
  '
}

job_block() {
  awk -v job="  $1:" '
    $0 == job { flag=1; print; next }
    flag && /^  [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  ' "$YAML"
}

input_block() {
  awk -v key="      $1:" '
    $0 == key { flag=1; print; next }
    flag && /^      [a-z0-9_]+:$/ { exit }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag && /^  [A-Za-z0-9_-]+:/ { exit }
    flag && /^[^[:space:]][^:]*:/ { exit }
    flag { print }
  ' "$YAML"
}

input_default() {
  input_block "$1" | awk '/^        default:/ { sub(/^        default: */, ""); print; exit }'
}

input_type() {
  input_block "$1" | awk '/^        type:/ { sub(/^        type: */, ""); print; exit }'
}

job_permissions_block() {
  job_block "$1" | awk '
    /^    permissions:/ { flag=1; print; next }
    flag && /^    [A-Za-z0-9_-]+:/ { exit }
    flag { print }
  '
}

first_step_uses() {
  job_block "$1" | awk '
    /^    steps:/ { in_steps=1; next }
    in_steps && /^      - uses:[[:space:]]*/ { print; exit }
    in_steps && /^      - name:/ { in_first=1; next }
    in_steps && in_first && /^        uses:[[:space:]]*/ { print; exit }
    in_steps && in_first && /^      - / { exit }
    in_steps && /^    [A-Za-z0-9_-]+:/ { exit }
  '
}

@test "first_step_uses returns the first uses line for semantic pin checks" {
  tmp_yaml=$(mktemp "${TMPDIR:-/tmp}/security-scan-first-step.XXXXXX")
  cat >"$tmp_yaml" <<'EOF'
jobs:
  sample:
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111 # v7.0.0
      - name: Harden runner
        uses: step-security/harden-runner@2222222222222222222222222222222222222222 # v2.99.0
EOF

  original_yaml=$YAML
  YAML="$tmp_yaml"
  first_step=$(first_step_uses sample)
  YAML=$original_yaml
  rm -f "$tmp_yaml"

  assert_action_pin "$first_step" "actions/checkout"
}

workflow_call_input_keys() {
  on_block | awk '
    /^  workflow_call:$/ { in_call=1; next }
    in_call && /^    inputs:$/ { in_inputs=1; next }
    in_inputs && /^      [a-z0-9_]+:$/ {
      sub(/^      /, "", $0);
      sub(/:$/, "", $0);
      print;
      next
    }
    in_inputs && /^    [A-Za-z0-9_-]+:/ { exit }
  '
}

readme_security_section() {
  awk '
    /^## `security-scan.yml`$/ { flag=1; print; next }
    flag && /^## `/ { exit }
    flag { print }
  ' "$README"
}

@test "security-scan.yml is workflow_call only" {
  assert_eq "$(on_trigger_keys)" "workflow_call"
}

@test "public inputs and defaults match the v1 contract" {
  expected_inputs=$'run_codeql
run_trufflehog
run_zizmor
run_trivy
run_osv_full
run_osv_pr
zizmor_online_audits
support_merge_group
codeql_language
codeql_queries'

  observed_inputs=$(workflow_call_input_keys | sort)
  expected_sorted=$(printf "%s\n" "$expected_inputs" | sort)
  assert_eq "$observed_inputs" "$expected_sorted"

  for input in run_codeql run_trufflehog run_zizmor run_trivy run_osv_full run_osv_pr zizmor_online_audits support_merge_group; do
    assert_eq "$(input_type "$input")" "boolean"
  done

  assert_eq "$(input_default run_codeql)" "true"
  assert_eq "$(input_default run_trufflehog)" "true"
  assert_eq "$(input_default run_zizmor)" "true"
  assert_eq "$(input_default run_trivy)" "true"
  assert_eq "$(input_default run_osv_full)" "true"
  assert_eq "$(input_default run_osv_pr)" "true"
  assert_eq "$(input_default zizmor_online_audits)" "true"
  assert_eq "$(input_default support_merge_group)" "false"

  assert_eq "$(input_type codeql_language)" "string"
  assert_eq "$(input_default codeql_language)" '"python"'
  assert_eq "$(input_type codeql_queries)" "string"
  assert_eq "$(input_default codeql_queries)" '"security-extended"'
}

@test "workflow denies permissions at top level" {
  grep -qxF "permissions: {}" "$YAML"
}

@test "validate-event runs unconditionally with no permissions and fails unsupported events" {
  block=$(job_block validate-event)
  assert_contains "$block" "permissions: {}"
  assert_contains "$block" 'EVENT_NAME: ${{ github.event_name }}'
  assert_contains "$block" 'SUPPORT_MERGE_GROUP: ${{ inputs.support_merge_group }}'
  assert_contains "$block" "push|pull_request|schedule)"
  assert_contains "$block" "merge_group)"
  assert_contains "$block" 'if [[ "$SUPPORT_MERGE_GROUP" == "true" ]]'
  assert_contains "$block" "support_merge_group: true"
  assert_contains "$block" "Unsupported event"
}

@test "all scanner jobs depend on validate-event" {
  for job in codeql trufflehog zizmor trivy osv-full osv-pr; do
    assert_contains "$(job_block "$job")" "needs: validate-event"
  done
}

@test "general scanners use toggle plus supported-event gate including optional merge_group" {
  for job in codeql trufflehog zizmor trivy; do
    block=$(job_block "$job")
    assert_contains "$block" "inputs.run_${job}"
    assert_contains "$block" "github.event_name == 'push'"
    assert_contains "$block" "github.event_name == 'pull_request'"
    assert_contains "$block" "github.event_name == 'schedule'"
    assert_contains "$block" "github.event_name == 'merge_group' && inputs.support_merge_group"
  done
}

@test "OSV event gates are push/schedule for full and pull_request only for PR" {
  full=$(job_block osv-full)
  pr=$(job_block osv-pr)

  assert_contains "$full" "inputs.run_osv_full"
  assert_contains "$full" "github.event_name == 'push'"
  assert_contains "$full" "github.event_name == 'schedule'"
  assert_lacks "$full" "pull_request"
  assert_lacks "$full" "merge_group"

  assert_contains "$pr" "inputs.run_osv_pr"
  assert_contains "$pr" "github.event_name == 'pull_request'"
  assert_lacks "$pr" "github.event_name == 'push'"
  assert_lacks "$pr" "github.event_name == 'schedule'"
  assert_lacks "$pr" "merge_group"
}

@test "job permissions are least privilege" {
  assert_eq "$(job_permissions_block validate-event)" "    permissions: {}"
  assert_eq "$(job_permissions_block codeql)" $'    permissions:\n      actions: read\n      contents: read\n      security-events: write'
  assert_eq "$(job_permissions_block trufflehog)" $'    permissions:\n      contents: read'
  assert_eq "$(job_permissions_block zizmor)" $'    permissions:\n      contents: read'
  assert_eq "$(job_permissions_block trivy)" $'    permissions:\n      actions: read\n      contents: read\n      security-events: write'
  assert_eq "$(job_permissions_block osv-full)" $'    permissions:\n      actions: read\n      contents: read\n      security-events: write'
  assert_eq "$(job_permissions_block osv-pr)" $'    permissions:\n      actions: read\n      contents: read\n      security-events: write'
}

@test "step-based scanner jobs put harden-runner first" {
  for job in codeql trufflehog zizmor trivy; do
    first_step=$(first_step_uses "$job")
    assert_action_pin "$first_step" "step-security/harden-runner"
    block=$(job_block "$job")
    assert_contains "$block" "egress-policy: audit"
  done
}

@test "CodeQL is single-language, build-free, and category derives from codeql_language" {
  block=$(job_block codeql)
  assert_action_pin "$block" "github/codeql-action/init"
  assert_action_pin "$block" "github/codeql-action/analyze"
  assert_contains "$block" 'languages: ${{ inputs.codeql_language }}'
  assert_contains "$block" 'queries: ${{ inputs.codeql_queries }}'
  assert_contains "$block" "build-mode: none"
  assert_contains "$block" 'category: /language:${{ inputs.codeql_language }}'
  assert_lacks "$block" "matrix"
}

@test "TruffleHog defers range selection to the action default and uses verified results" {
  block=$(job_block trufflehog)
  assert_action_pin "$block" "actions/checkout"
  assert_contains "$block" "fetch-depth: 0"
  assert_contains "$block" "persist-credentials: false"
  assert_action_pin "$block" "trufflesecurity/trufflehog"
  assert_contains "$block" "continue-on-error: true"
  assert_contains "$block" "extra_args: --results=verified"
  assert_contains "$block" "steps.trufflehog.outcome == 'failure'"
  assert_contains "$block" "TruffleHog scan failed or detected verified secrets."
  assert_lacks "$block" "base:"
  assert_lacks "$block" "head:"
  assert_lacks "$block" "--only-verified"
}

@test "Zizmor is blocking with medium thresholds, online-audits input, and pinned CLI" {
  block=$(job_block zizmor)
  assert_action_pin "$block" "zizmorcore/zizmor-action"
  assert_contains "$block" 'online-audits: ${{ inputs.zizmor_online_audits }}'
  assert_contains "$block" "advanced-security: false"
  assert_contains "$block" "min-severity: medium"
  assert_contains "$block" "min-confidence: medium"
  assert_contains "$block" 'version: "1.26.1"'
}

@test "Trivy is one fs SARIF run with fail-on-findings and explicit SARIF category" {
  block=$(job_block trivy)
  assert_action_pin "$block" "aquasecurity/trivy-action"
  assert_contains "$block" "scan-type: fs"
  assert_contains "$block" "format: sarif"
  assert_contains "$block" "output: trivy-results.sarif"
  assert_contains "$block" "severity: CRITICAL,HIGH"
  assert_contains "$block" "limit-severities-for-sarif: true"
  assert_contains "$block" 'exit-code: "1"'
  assert_contains "$block" "if: always()"
  assert_action_pin "$block" "github/codeql-action/upload-sarif"
  assert_contains "$block" "category: trivy"
}

@test "OSV wraps Google reusable workflows with explicit recursive scan args" {
  full=$(job_block osv-full)
  pr=$(job_block osv-pr)

  assert_action_pin "$full" "google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml"
  assert_action_pin "$pr" "google/osv-scanner-action/.github/workflows/osv-scanner-reusable-pr.yml"
  assert_contains "$full" "scan-args: --recursive ./"
  assert_contains "$pr" "scan-args: --recursive ./"
}

@test "no scanner threshold or package-manager inputs are exposed" {
  [ -f "$YAML" ]

  for forbidden in trivy_severity trivy_scanners trivy_ignore_unfixed zizmor_min_severity zizmor_min_confidence package_manager; do
    if grep -q "$forbidden" "$YAML"; then
      echo "unexpected public input or setting: $forbidden"
      return 1
    fi
  done
}

@test "README documents the security-scan input contract" {
  block=$(readme_security_section)

  assert_contains "$block" "### Inputs"
  assert_contains "$block" '| `run_codeql` | boolean | no | `true` | Run CodeQL analysis. Set to `false` for repos using CodeQL default setup or another CodeQL workflow. |'
  assert_contains "$block" '| `run_trufflehog` | boolean | no | `true` | Run TruffleHog verified-secret scanning. |'
  assert_contains "$block" '| `run_zizmor` | boolean | no | `true` | Run Zizmor workflow analysis as a blocking console gate. |'
  assert_contains "$block" '| `run_trivy` | boolean | no | `true` | Run Trivy filesystem vulnerability scanning. |'
  assert_contains "$block" '| `run_osv_full` | boolean | no | `true` | Run OSV full scans on `push` and `schedule`. |'
  assert_contains "$block" '| `run_osv_pr` | boolean | no | `true` | Run OSV PR diff scans on `pull_request`. Never runs on `merge_group`. |'
  assert_contains "$block" '| `codeql_language` | string | no | `"python"` | Single CodeQL language token. Use `javascript-typescript` for Node callers. |'
  assert_contains "$block" '| `codeql_queries` | string | no | `"security-extended"` | CodeQL query suite. Use `+security-and-quality` to include quality queries. |'
  assert_contains "$block" '| `zizmor_online_audits` | boolean | no | `true` | Enable Zizmor online audits, including vulnerable-action checks. |'
  assert_contains "$block" '| `support_merge_group` | boolean | no | `false` | Allow general scanners on `merge_group`; unsupported `merge_group` callers fail closed. |'
}
