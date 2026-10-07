#!/usr/bin/env bats
# security-workflow-contract.bats - static contract tests for this repo's own
# Zizmor workflow.

YAML=".github/workflows/security.yml"

@test "zizmor SARIF findings fail the job after upload" {
  # SARIF mode uploads findings but exits 0, so a gate step must follow.
  ruby -r yaml -e '
    steps = YAML.safe_load(File.read(ARGV[0])).dig("jobs", "zizmor", "steps")
    scan = steps.index { |s| s["uses"].to_s.start_with?("zizmorcore/zizmor-action@") }
    abort "no zizmor-action step" unless scan
    abort "zizmor-action must set id" unless steps[scan]["id"]
    abort "advanced-security must be true" unless steps[scan].dig("with", "advanced-security") == true
    gate = steps[(scan + 1)..].find { |s| s["run"].to_s.include?("scripts/zizmor-sarif-gate.sh \"$SARIF_FILE\"") }
    abort "no gate step after zizmor-action" unless gate
    expected = "${{ steps.#{steps[scan]["id"]}.outputs.output-file }}"
    abort "gate SARIF_FILE must be #{expected}" unless gate.dig("env", "SARIF_FILE") == expected
  ' "$YAML"
}
