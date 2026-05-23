#!/usr/bin/env bats
# guard-runtime.bats — execute each workflow's Layer 3 guard block against
# representative input combinations and assert the GUARD_TRIGGERED outcome.
#
# Why: tests/guard-shape.bats only checks LINE ORDERING. If someone wraps the
# UNSUPPORTED_PATHS branch back under an outer `if [ -z "$DEPS_TSV" ]; then`,
# the line ordering is unchanged and shape tests pass — but the issue #62
# silent-green path returns. These tests source the actual block as bash
# and verify behaviour with non-empty DEPS_TSV + non-empty UNSUPPORTED_PATHS,
# which is exactly the case the outer-if regression would mishandle.

# Extract from the Layer 3 comment marker through the first `fi` line that
# starts at exactly 10 leading spaces (the `run: |` indent). Strip those 10
# spaces so the result is plain bash. If a future refactor wraps the inner
# if/elif in an outer `if [ ... ]; then ... fi` (also at 10 spaces), the
# OUTER fi terminates the capture and is included — that's intentional, and
# the eval'd block then no longer triggers under the issue #62 inputs.
extract_guard_block() {
  local yaml="$1"
  awk '/^[[:space:]]+# --- Layer 3:/{flag=1} flag {print} flag && /^          fi[[:space:]]*$/{exit}' "$yaml" \
    | sed -E 's/^          //'
}

@test "cooldown: issue #62 case (DEPS_TSV non-empty + UNSUPPORTED non-empty) — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-cooldown.yml)
  DEPS_TSV=$'mypy\t1.20.1\tpypi'
  TOUCHED_PATHS=$'package-lock.json\nuv.lock'
  UNSUPPORTED_PATHS="package-lock.json"
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"does not support"* ]]
}

@test "safety: issue #62 case (DEPS_TSV non-empty + UNSUPPORTED non-empty) — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'mypy\t1.20.1\tpypi'
  TOUCHED_PATHS=$'package-lock.json\nuv.lock'
  UNSUPPORTED_PATHS="package-lock.json"
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"does not support"* ]]
}

@test "cooldown: issue #52 case (DEPS_TSV empty + TOUCHED non-empty + UNSUPPORTED empty) — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-cooldown.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="uv.lock"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"Parser could not extract"* ]]
}

@test "safety: issue #52 case (DEPS_TSV empty + TOUCHED non-empty + UNSUPPORTED empty) — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="uv.lock"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"Parser could not extract"* ]]
}

@test "cooldown: clean supported case (DEPS_TSV non-empty + UNSUPPORTED empty) — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-cooldown.yml)
  DEPS_TSV=$'requests\t2.32.0\tpypi'
  TOUCHED_PATHS="requirements.txt"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

@test "safety: clean supported case (DEPS_TSV non-empty + UNSUPPORTED empty) — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'requests\t2.32.0\tpypi'
  TOUCHED_PATHS="requirements.txt"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

@test "cooldown: no touched paths (empty diff) — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-cooldown.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=""
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

@test "safety: no touched paths (empty diff) — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=""
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}
