#!/usr/bin/env bash
# safety-verdict.sh — translate dependency-safety scan facts to a gate verdict.
#
# Pure logic: no network, no `gh` calls, no I/O beyond stdin/stdout.
# Fail-closed: invalid/missing env → diagnostic on stderr, non-zero exit.
# The workflow MUST treat non-zero exit as: gate_state=error,
# has_safety_error=true, auto_merge_ok=false.
#
# Inputs (env vars, all required):
#   GUARD_TRIGGERED         true|false
#   AGE_ERROR_COUNT         int >=0
#   AGE_VIOLATION_COUNT     int >=0
#   SCAN_ERROR_COUNT        int >=0  (GHSA/OSV only — scorecard failures excluded)
#   ADVISORY_COUNT          int >=0  (post version-aware filtering)
#   RELEASE_AGE_POLICY      off|advisory|blocking
#   MINIMUM_RELEASE_AGE_DAYS int >=0 (status text only; ignored when policy=off)
#   AUTO_MERGE              true|false
#
# Contract invariant: RELEASE_AGE_POLICY=off requires AGE_ERROR_COUNT=0 and
# AGE_VIOLATION_COUNT=0 — no age data may exist when no lookup ran. A
# violation indicates an orchestrator bug and fails closed (exit 2).
#
# Output (stdout, single TSV line, six fields, no trailing newline beyond one):
#   gate_state\tauto_merge_ok\thas_safety_error\thas_age_violation\thas_security_review\tstatus_desc
#
# Bash 3.2 compatible (macOS system bash).

set -uo pipefail

die() {
  printf 'safety-verdict.sh: %s\n' "$1" >&2
  exit 2
}

require_bool() {
  local name="$1"
  local val
  eval "val=\${$name-__unset__}"
  case "$val" in
    __unset__) die "missing required env: $name" ;;
    true|false) ;;
    *) die "$name must be 'true' or 'false', got: $val" ;;
  esac
}

require_nonneg_int() {
  local name="$1"
  local val
  eval "val=\${$name-__unset__}"
  if [ "$val" = "__unset__" ]; then
    die "missing required env: $name"
  fi
  case "$val" in
    ''|*[!0-9]*) die "$name must be a non-negative integer, got: $val" ;;
  esac
}

require_policy() {
  local val
  val=${RELEASE_AGE_POLICY-__unset__}
  case "$val" in
    __unset__) die "missing required env: RELEASE_AGE_POLICY" ;;
    off|advisory|blocking) ;;
    false) die "RELEASE_AGE_POLICY must be off|advisory|blocking, got: false (unquoted YAML off parses as boolean false — quote it: \"off\")" ;;
    *) die "RELEASE_AGE_POLICY must be off|advisory|blocking, got: $val" ;;
  esac
}

require_bool GUARD_TRIGGERED
require_policy
require_bool AUTO_MERGE
require_nonneg_int AGE_ERROR_COUNT
require_nonneg_int AGE_VIOLATION_COUNT
require_nonneg_int SCAN_ERROR_COUNT
require_nonneg_int ADVISORY_COUNT
require_nonneg_int MINIMUM_RELEASE_AGE_DAYS

# Contract invariant (see header): no age data may exist when policy is off.
if [ "$RELEASE_AGE_POLICY" = "off" ]; then
  if [ "$AGE_VIOLATION_COUNT" -gt 0 ]; then
    die "RELEASE_AGE_POLICY=off but AGE_VIOLATION_COUNT=$AGE_VIOLATION_COUNT (orchestrator bug)"
  fi
  if [ "$AGE_ERROR_COUNT" -gt 0 ]; then
    die "RELEASE_AGE_POLICY=off but AGE_ERROR_COUNT=$AGE_ERROR_COUNT (orchestrator bug)"
  fi
fi

error_total=$(( AGE_ERROR_COUNT + SCAN_ERROR_COUNT ))

# --- gate_state (priority order) ---
if [ "$GUARD_TRIGGERED" = "true" ]; then
  gate_state="error"
elif [ "$error_total" -gt 0 ]; then
  gate_state="error"
elif [ "$AGE_VIOLATION_COUNT" -gt 0 ] && [ "$RELEASE_AGE_POLICY" = "blocking" ]; then
  gate_state="failure"
else
  gate_state="success"
fi

# --- label booleans (independent facts) ---
if [ "$GUARD_TRIGGERED" = "true" ] || [ "$error_total" -gt 0 ]; then
  has_safety_error="true"
else
  has_safety_error="false"
fi

if [ "$AGE_VIOLATION_COUNT" -gt 0 ]; then
  has_age_violation="true"
else
  has_age_violation="false"
fi

if [ "$ADVISORY_COUNT" -gt 0 ]; then
  has_security_review="true"
else
  has_security_review="false"
fi

# --- auto_merge_ok (final boolean) ---
if [ "$AUTO_MERGE" = "true" ] \
   && [ "$GUARD_TRIGGERED" = "false" ] \
   && [ "$error_total" -eq 0 ] \
   && [ "$AGE_VIOLATION_COUNT" -eq 0 ] \
   && [ "$ADVISORY_COUNT" -eq 0 ]; then
  auto_merge_ok="true"
else
  auto_merge_ok="false"
fi

# --- status_desc (≤140 chars, composed per priority winner) ---
if [ "$GUARD_TRIGGERED" = "true" ]; then
  status_desc="Could not extract dependencies from diff. Manual review required."
elif [ "$error_total" -gt 0 ]; then
  status_desc="Scan errors: ${AGE_ERROR_COUNT} age lookup(s), ${SCAN_ERROR_COUNT} advisory query/ies. Re-run or push to retry."
elif [ "$AGE_VIOLATION_COUNT" -gt 0 ] && [ "$RELEASE_AGE_POLICY" = "blocking" ]; then
  status_desc="${AGE_VIOLATION_COUNT} package(s) younger than ${MINIMUM_RELEASE_AGE_DAYS}d minimum release age (blocking policy)."
elif [ "$ADVISORY_COUNT" -gt 0 ]; then
  status_desc="${ADVISORY_COUNT} advisory/ies found (version-filtered). Manual review required."
elif [ "$AGE_VIOLATION_COUNT" -gt 0 ]; then
  status_desc="${AGE_VIOLATION_COUNT} package(s) below ${MINIMUM_RELEASE_AGE_DAYS}d minimum release age (advisory policy). Auto-merge suppressed."
elif [ "$auto_merge_ok" = "true" ]; then
  if [ "$RELEASE_AGE_POLICY" = "off" ]; then
    status_desc="Clean scan (no advisories). Auto-merge enabled."
  else
    status_desc="Clean scan (≥${MINIMUM_RELEASE_AGE_DAYS}d, no advisories). Auto-merge enabled."
  fi
else
  if [ "$RELEASE_AGE_POLICY" = "off" ]; then
    status_desc="Clean scan (no advisories). Ready for merge."
  else
    status_desc="Clean scan (≥${MINIMUM_RELEASE_AGE_DAYS}d, no advisories). Ready for merge."
  fi
fi

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$gate_state" "$auto_merge_ok" \
  "$has_safety_error" "$has_age_violation" "$has_security_review" \
  "$status_desc"
