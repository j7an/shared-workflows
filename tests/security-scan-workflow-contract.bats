#!/usr/bin/env bats
# security-scan-workflow-contract.bats - static contract tests for the
# reusable security scanning workflow.

YAML=".github/workflows/security-scan.yml"

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
    flag && /^      [a-z_]+:$/ { exit }
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
    in_steps && /^      - uses:[[:space:]]*/ { sub(/^      - uses:[[:space:]]*/, "", $0); print; exit }
    in_steps && /^      - name:/ { in_first=1; next }
    in_steps && in_first && /^        uses:[[:space:]]*/ { sub(/^        uses:[[:space:]]*/, "", $0); print; exit }
    in_steps && in_first && /^      - / { exit }
    in_steps && /^    [A-Za-z0-9_-]+:/ { exit }
  '
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

@test "security-scan.yml is workflow_call only" {
  [ "$(on_trigger_keys)" = "workflow_call" ]
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
  [[ "$observed_inputs" = "$expected_sorted" ]]

  for input in run_codeql run_trufflehog run_zizmor run_trivy run_osv_full run_osv_pr zizmor_online_audits support_merge_group; do
    [ "$(input_type "$input")" = "boolean" ]
  done

  [ "$(input_default run_codeql)" = "true" ]
  [ "$(input_default run_trufflehog)" = "true" ]
  [ "$(input_default run_zizmor)" = "true" ]
  [ "$(input_default run_trivy)" = "true" ]
  [ "$(input_default run_osv_full)" = "true" ]
  [ "$(input_default run_osv_pr)" = "true" ]
  [ "$(input_default zizmor_online_audits)" = "true" ]
  [ "$(input_default support_merge_group)" = "false" ]

  [ "$(input_type codeql_language)" = "string" ]
  [ "$(input_default codeql_language)" = '"python"' ]
  [ "$(input_type codeql_queries)" = "string" ]
  [ "$(input_default codeql_queries)" = '"security-extended"' ]
}

@test "workflow denies permissions at top level" {
  grep -qxF "permissions: {}" "$YAML"
}

@test "validate-event runs unconditionally with no permissions and fails unsupported events" {
  block=$(job_block validate-event)
  [[ "$block" == *"permissions: {}"* ]]
  [[ "$block" == *'EVENT_NAME: ${{ github.event_name }}'* ]]
  [[ "$block" == *'SUPPORT_MERGE_GROUP: ${{ inputs.support_merge_group }}'* ]]
  [[ "$block" == *"push|pull_request|schedule)"* ]]
  [[ "$block" == *"merge_group)"* ]]
  [[ "$block" == *"support_merge_group: true"* ]]
  [[ "$block" == *"Unsupported event"* ]]
}

@test "all scanner jobs depend on validate-event" {
  for job in codeql trufflehog zizmor trivy osv-full osv-pr; do
    [[ "$(job_block "$job")" == *"needs: validate-event"* ]]
  done
}

@test "general scanners use toggle plus supported-event gate including optional merge_group" {
  for job in codeql trufflehog zizmor trivy; do
    block=$(job_block "$job")
    [[ "$block" == *"inputs.run_${job}"* ]]
    [[ "$block" == *"github.event_name == 'push'"* ]]
    [[ "$block" == *"github.event_name == 'pull_request'"* ]]
    [[ "$block" == *"github.event_name == 'schedule'"* ]]
    [[ "$block" == *"github.event_name == 'merge_group' && inputs.support_merge_group"* ]]
  done
}

@test "OSV event gates are push/schedule for full and pull_request only for PR" {
  full=$(job_block osv-full)
  pr=$(job_block osv-pr)

  [[ "$full" == *"inputs.run_osv_full"* ]]
  [[ "$full" == *"github.event_name == 'push'"* ]]
  [[ "$full" == *"github.event_name == 'schedule'"* ]]
  [[ "$full" != *"pull_request"* ]]
  [[ "$full" != *"merge_group"* ]]

  [[ "$pr" == *"inputs.run_osv_pr"* ]]
  [[ "$pr" == *"github.event_name == 'pull_request'"* ]]
  [[ "$pr" != *"merge_group"* ]]
}

@test "job permissions are least privilege" {
  [ "$(job_permissions_block validate-event)" = "    permissions: {}" ]

  codeql_perms=$(job_permissions_block codeql)
  [[ "$codeql_perms" == *"contents: read"* ]]
  [[ "$codeql_perms" == *"security-events: write"* ]]
  [[ "$codeql_perms" == *"actions: read"* ]]

  [ "$(job_permissions_block trufflehog)" = $'    permissions:\n      contents: read' ]

  for job in zizmor trivy; do
    perms=$(job_permissions_block "$job")
    [[ "$perms" == *"contents: read"* ]]
    [[ "$perms" == *"security-events: write"* ]]
    [[ "$perms" != *"actions: read"* ]]
  done

  for job in osv-full osv-pr; do
    perms=$(job_permissions_block "$job")
    [[ "$perms" == *"actions: read"* ]]
    [[ "$perms" == *"contents: read"* ]]
    [[ "$perms" == *"security-events: write"* ]]
  done
}

@test "step-based scanner jobs put harden-runner first" {
  for job in codeql trufflehog zizmor trivy; do
    [ "$(first_step_uses "$job")" = "step-security/harden-runner@9af89fc71515a100421586dfdb3dc9c984fbf411 # v2.19.4" ]
    [[ "$(job_block "$job")" == *"egress-policy: audit"* ]]
  done
}

@test "CodeQL is single-language, build-free, and category derives from codeql_language" {
  block=$(job_block codeql)
  [[ "$block" == *"github/codeql-action/init@8aad20d150bbac5944a9f9d289da16a4b0d87c1e # v4.36.2"* ]]
  [[ "$block" == *"github/codeql-action/analyze@8aad20d150bbac5944a9f9d289da16a4b0d87c1e # v4.36.2"* ]]
  [[ "$block" == *'languages: ${{ inputs.codeql_language }}'* ]]
  [[ "$block" == *'queries: ${{ inputs.codeql_queries }}'* ]]
  [[ "$block" == *"build-mode: none"* ]]
  [[ "$block" == *'category: /language:${{ inputs.codeql_language }}'* ]]
  [[ "$block" != *"matrix"* ]]
}

@test "TruffleHog defers range selection to the action default and uses verified results" {
  block=$(job_block trufflehog)
  [[ "$block" == *"actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0"* ]]
  [[ "$block" == *"fetch-depth: 0"* ]]
  [[ "$block" == *"persist-credentials: false"* ]]
  [[ "$block" == *"trufflesecurity/trufflehog@30d5bb91af1a771378349dbbb0c82129392acf70 # v3.95.6"* ]]
  [[ "$block" == *"continue-on-error: true"* ]]
  [[ "$block" == *"extra_args: --results=verified"* ]]
  [[ "$block" == *"steps.trufflehog.outcome == 'failure'"* ]]
  [[ "$block" != *"base:"* ]]
  [[ "$block" != *"head:"* ]]
  [[ "$block" != *"--only-verified"* ]]
}

@test "Zizmor is blocking with medium thresholds, online-audits input, and pinned CLI" {
  block=$(job_block zizmor)
  [[ "$block" == *"zizmorcore/zizmor-action@192e21d79ab29983730a13d1382995c2307fbcaa # v0.5.7"* ]]
  [[ "$block" == *'online-audits: ${{ inputs.zizmor_online_audits }}'* ]]
  [[ "$block" == *"advanced-security: false"* ]]
  [[ "$block" == *"min-severity: medium"* ]]
  [[ "$block" == *"min-confidence: medium"* ]]
  [[ "$block" == *'version: "1.26.1"'* ]]
}

@test "Trivy is one fs SARIF run with fail-on-findings and explicit SARIF category" {
  block=$(job_block trivy)
  [ "$(grep -c "aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0" <<< "$block")" -eq 1 ]
  [[ "$block" == *"scan-type: fs"* ]]
  [[ "$block" == *"format: sarif"* ]]
  [[ "$block" == *"output: trivy-results.sarif"* ]]
  [[ "$block" == *"severity: CRITICAL,HIGH"* ]]
  [[ "$block" == *'exit-code: "1"'* ]]
  [[ "$block" == *"if: always()"* ]]
  [[ "$block" == *"github/codeql-action/upload-sarif@8aad20d150bbac5944a9f9d289da16a4b0d87c1e # v4.36.2"* ]]
  [[ "$block" == *"category: trivy"* ]]
}

@test "OSV wraps Google reusable workflows with explicit recursive scan args" {
  full=$(job_block osv-full)
  pr=$(job_block osv-pr)

  [[ "$full" == *"google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@9a498708959aeaef5ef730655706c5a1df1edbc2 # v2.3.8"* ]]
  [[ "$pr" == *"google/osv-scanner-action/.github/workflows/osv-scanner-reusable-pr.yml@9a498708959aeaef5ef730655706c5a1df1edbc2 # v2.3.8"* ]]
  [[ "$full" == *"scan-args: --recursive ./"* ]]
  [[ "$pr" == *"scan-args: --recursive ./"* ]]
}

@test "no scanner threshold or package-manager inputs are exposed" {
  for forbidden in trivy_severity trivy_scanners trivy_ignore_unfixed zizmor_min_severity zizmor_min_confidence package_manager; do
    if grep -q "$forbidden" "$YAML"; then
      echo "unexpected public input or setting: $forbidden"
      return 1
    fi
  done
}
