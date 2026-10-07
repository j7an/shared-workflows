#!/usr/bin/env bats
# security-workflow-contract.bats - static contract tests for this repo's own
# Zizmor workflow.

YAML=".github/workflows/security.yml"

@test "zizmor SARIF findings fail the job after upload" {
  # SARIF mode uploads findings but exits 0, so a gate step must follow.
  # Values are compared as compact JSON: yq's own == is neither deep nor type-strict.
  local scan id gate
  scan=$(yq '.jobs.zizmor.steps | to_entries | map(select((.value.uses // "") | test("^zizmorcore/zizmor-action@"))) | .[0].key' "$YAML")
  [ "$scan" != null ] || { echo 'no zizmor-action step'; return 1; }
  id=$(yq ".jobs.zizmor.steps[$scan].id // \"\"" "$YAML")
  [ -n "$id" ] || { echo 'zizmor-action must set id'; return 1; }
  [ "$(yq -o=json -I=0 ".jobs.zizmor.steps[$scan].with[\"advanced-security\"]" "$YAML")" = true ]
  gate='.jobs.zizmor.steps | to_entries | map(select(.key > '"$scan"' and ((.value.run // "") | contains("scripts/zizmor-sarif-gate.sh \"$SARIF_FILE\"")))) | .[0].value'
  [ "$(yq "$gate | . != null" "$YAML")" = true ] || { echo 'no gate step after zizmor-action'; return 1; }
  [ "$(yq -o=json -I=0 "$gate | .env.SARIF_FILE" "$YAML")" = "\"\${{ steps.$id.outputs.output-file }}\"" ]
}
