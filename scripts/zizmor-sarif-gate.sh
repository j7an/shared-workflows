#!/usr/bin/env bash
# zizmor-sarif-gate.sh — fail the job when uploaded Zizmor SARIF has findings.
#
# Usage: scripts/zizmor-sarif-gate.sh <sarif-path>
# Exit: 0 = no findings, 1 = findings, 2 = unusable input.
# Pass/finding messages go to stdout; fail-closed diagnostics go to stderr.
# Bash 3.2 compatible. No network or upload; the action uploads SARIF first.

set -uo pipefail

path=${1:-}
if [ -z "$path" ]; then
  printf '%s\n' '::error::Zizmor SARIF gate: no SARIF path provided' >&2
  exit 2
fi

if [ ! -r "$path" ] || [ ! -s "$path" ]; then
  printf '::error::Zizmor SARIF gate: SARIF file not found or unreadable: %s\n' "$path" >&2
  exit 2
fi

if ! count=$(jq '[.runs[].results[]] | length' "$path" 2>/dev/null) || ! [[ "$count" =~ ^[0-9]+$ ]]; then
  printf '::error::Zizmor SARIF gate: SARIF file is not valid SARIF JSON: %s\n' "$path" >&2
  exit 2
fi

if [ "$count" -eq 0 ]; then
  printf '%s\n' 'Zizmor: no findings at the configured thresholds.'
  exit 0
fi

jq -r '.runs[].results[] | "\(.ruleId) \(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine)"' "$path"
printf '::error::Zizmor reported %s finding(s); see the Security tab (code scanning, category: zizmor).\n' "$count"
exit 1
