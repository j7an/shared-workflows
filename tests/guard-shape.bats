#!/usr/bin/env bats
# guard-shape.bats — static assertions that the safety workflow composes the
# Layer 3 guard in the required order: UNSUPPORTED_PATHS branch first
# (issue #62), then the zero-rows fallback branch (issue #52).
#
# Why: the composed Layer 3 logic lives in workflow YAML and is not directly
# unit-testable; this guard prevents accidental ordering regressions.

WORKFLOWS=(
  ".github/workflows/dependency-safety.yml"
)

@test "dependency-safety.yml: TOUCHED_PATHS/UNSUPPORTED_PATHS hoisted above Layer 2" {
  yaml=".github/workflows/dependency-safety.yml"
  hoist_line=$(grep -n "UNSUPPORTED_PATHS=\$(printf" "$yaml" | head -1 | cut -d: -f1)
  layer2_line=$(grep -n "Layer 2: PR-body fallback" "$yaml" | head -1 | cut -d: -f1)
  [ -n "$hoist_line" ]
  [ -n "$layer2_line" ]
  [ "$hoist_line" -lt "$layer2_line" ]
}

@test "dependency-safety.yml: Layer 3 guard checks UNSUPPORTED_PATHS before zero-rows elif" {
  yaml=".github/workflows/dependency-safety.yml"
  unsupported_line=$(grep -n 'if \[ -n "\$UNSUPPORTED_PATHS" \]; then' "$yaml" | head -1 | cut -d: -f1)
  elif_line=$(grep -n 'elif \[ -z "\$(echo "\$DEPS_TSV" | sed' "$yaml" | head -1 | cut -d: -f1)
  [ -n "$unsupported_line" ]
  [ -n "$elif_line" ]
  [ "$unsupported_line" -lt "$elif_line" ]
}

@test "both workflows: classify_touched_paths is called (not just defined)" {
  for yaml in "${WORKFLOWS[@]}"; do
    # 2 occurrences: 1 inline function definition, 1 call site.
    count=$(grep -c "classify_touched_paths" "$yaml")
    [ "$count" -ge 2 ] || { echo "FAIL: $yaml has only $count classify_touched_paths references"; return 1; }
  done
}

@test "dependency-safety.yml: non-bot status write is permission-aware (dual matcher)" {
  yaml=".github/workflows/dependency-safety.yml"
  # The non-bot success POST is captured (not unconditional).
  grep -q 'if err=$(gh api "repos/${GH_REPO}/statuses/${HEAD_SHA}"' "$yaml"
  # The known read-only denial is matched on BOTH the permission message and a 403 marker.
  grep -q "Resource not accessible by integration" "$yaml"
  grep -Eq "HTTP 403|\"status\":\"403\"" "$yaml"
}
