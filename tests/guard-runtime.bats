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

@test "safety: issue #62 case (DEPS_TSV non-empty + UNSUPPORTED non-empty) — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'mypy\t1.20.1\tpypi'
  TOUCHED_PATHS=$'package-lock.json\nuv.lock'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="package-lock.json"
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"does not support"* ]]
}

@test "safety: issue #52 case (DEPS_TSV empty + TOUCHED non-empty + UNSUPPORTED empty) — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="uv.lock"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"Parser could not extract"* ]]
}

@test "safety: clean supported case (DEPS_TSV non-empty + UNSUPPORTED empty) — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'requests\t2.32.0\tpypi'
  TOUCHED_PATHS="requirements.txt"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

@test "safety: npm lockfile-only bump (all paths cleared) — guard does NOT fire" {
  # End state of a pnpm lockfile-only security update: the npm helper proved the
  # lockfile bump-only, so its path is subtracted from BOTH guard inputs and
  # zero tier-1 rows is the CORRECT answer. If the composition ever stops
  # subtracting from EFFECTIVE_TOUCHED, this becomes a false red on every
  # lockfile-only Dependabot PR.
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="pnpm-lock.yaml"
  EFFECTIVE_TOUCHED=""
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

@test "safety: npm manifest the helper could not clear — guard fires" {
  # A package.json carrying a disqualifier (e.g. a postinstall edit) fails
  # closed in npm_bump_extract, so nothing is cleared and both paths stay in
  # UNSUPPORTED_PATHS. Silent-green here would be issue #62 for npm.
  #
  # `|| return 1` is load-bearing: bash 3.2 does not apply `set -e` to a failing
  # `[[ ]]`, so a bare mid-body `[[ ]]` never fails a test on macOS.
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=$'package.json\npnpm-lock.yaml'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"does not support"* ]] || return 1
  [[ "$EXTRACTION_WARNING" == *"package.json"* ]] || return 1
  [[ "$EXTRACTION_WARNING" == *"pnpm-lock.yaml"* ]] || return 1
}

@test "safety: no touched paths (empty diff) — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=""
  EFFECTIVE_TOUCHED=""
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

@test "safety: npm rejection reason replaces the unsupported wording" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=$'tests/container/package.json\ntests/container/pnpm-lock.yaml'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  NPM_REJECTION='`the reason`'
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *'`the reason`'* ]] || return 1
  [[ "$EXTRACTION_WARNING" != *"does not support"* ]] || return 1
}

@test "safety: mixed PR keeps unsupported wording for the file the parser cannot handle" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=$'package-lock.json\npackage.json\npnpm-lock.yaml'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  NPM_REJECTION='`the reason`'
  eval "$block"
  [[ "$EXTRACTION_WARNING" == *'`the reason`'* ]] || return 1
  [[ "$EXTRACTION_WARNING" == *"does not support (package-lock.json)"* ]] || return 1
}

@test "safety: a reason is not shown when no npm path is unsupported" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="package-lock.json"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="package-lock.json"
  NPM_REJECTION='`the reason`'
  eval "$block"
  [[ "$EXTRACTION_WARNING" == *"does not support (package-lock.json)"* ]] || return 1
  [[ "$EXTRACTION_WARNING" != *"the reason"* ]] || return 1
}

@test "safety: unresolved Dockerfile build argument — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'${BASE}\t-\tdocker'
  TOUCHED_PATHS=Dockerfile
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
  [[ "$EXTRACTION_WARNING" == *"cannot resolve"* ]]
}

@test "safety: unparsed FROM alongside an extracted package — guard fires" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'requests\t2.32.5\tpypi\nFROM\t-\tdocker'
  TOUCHED_PATHS=$'Dockerfile\nrequirements.txt'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "true" ]
}

@test "safety: resolved image only — guard does NOT fire" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'python\t3.13\tdocker'
  TOUCHED_PATHS=Dockerfile
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_TRIGGERED" = "false" ]
}

# --- GUARD_STATUS_DESC (issue #225) -----------------------------------------
# The sentences below are the contract: they are the commit status text.

@test "status: unsupported file is named (stand-in for dep-rank#271)" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'mypy\t1.20.1\tpypi'
  TOUCHED_PATHS=$'package-lock.json\nuv.lock'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="package-lock.json"
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Unsupported dependency file: package-lock.json. Manual review required." ]
}

@test "status: several unsupported files name the first and count the rest" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=$'Pipfile\npackage-lock.json'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Unsupported dependency file: Pipfile (+1 more). Manual review required." ]
}

@test "status: npm rejection names the file the parser's diagnostic names" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=$'package.json\npnpm-lock.yaml'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  # Real shapes for a valid package.json bump beside a rejected lockfile.
  NPM_REJECTION='`pnpm-lock.yaml: change under unsupported lockfile section: settings:` (+1 more, see workflow log)'
  NPM_REJECTION_RAW='pnpm-lock.yaml: change under unsupported lockfile section: settings:'
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Dependency parser rejected pnpm-lock.yaml (+1 more). Manual review required." ]
}

@test "status: npm rejection whose diagnostic names no touched path falls back to the first npm path" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS=$'package-lock.json\npackage.json\npnpm-lock.yaml'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  NPM_REJECTION='`the reason`'
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Dependency parser rejected package.json (+2 more). Manual review required." ]
}

@test "status: zero rows names the touched file" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="uv.lock"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "No dependencies extracted from uv.lock. Manual review required." ]
}

@test "status: unresolved FROM names the sole Dockerfile-type path, nested and beside a package file" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'requests\t2.32.5\tpypi\n${BASE}:2\t-\tdocker'
  TOUCHED_PATHS=$'docker/Containerfile\nrequirements.txt'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Unresolved FROM line in docker/Containerfile. Manual review required." ]
}

@test "status: unresolved FROM recognizes each Dockerfile basename pattern" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'${BASE}\t-\tdocker'
  UNSUPPORTED_PATHS=""
  for p in Dockerfile Containerfile svc/api.Dockerfile Dockerfile.dev; do
    TOUCHED_PATHS="$p"
    EFFECTIVE_TOUCHED="$p"
    eval "$block"
    [ "$GUARD_STATUS_DESC" = "Unresolved FROM line in $p. Manual review required." ] || return 1
  done
}

@test "status: unresolved FROM stays generic with several Dockerfile-type paths" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'${BASE}\t-\tdocker'
  TOUCHED_PATHS=$'Dockerfile\ndocker/Containerfile'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Dockerfile FROM line could not be resolved to an image. Manual review required." ]
}

@test "status: unresolved FROM stays generic with no Dockerfile-type path" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'requests\t2.32.5\tpypi\n${BASE}:2\t-\tdocker'
  TOUCHED_PATHS="requirements.txt"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Dockerfile FROM line could not be resolved to an image. Manual review required." ]
}

@test "status: empty when the guard does not fire" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=$'requests\t2.32.0\tpypi'
  TOUCHED_PATHS="requirements.txt"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=""
  eval "$block"
  [ -z "$GUARD_STATUS_DESC" ]
}

@test "status: a long path and many files stay within 140 characters for every path-bearing cause" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  long="$(printf 'a%.0s' $(seq 1 250))/deep/nested/package.json"
  many=$(seq 1 1500 | sed 's|^|dir|; s|$|/Pipfile|')
  all="$long"$'\n'"$many"

  # unsupported (no npm reason, so the unsupported wording applies)
  DEPS_TSV="" TOUCHED_PATHS="$all" EFFECTIVE_TOUCHED="$all" UNSUPPORTED_PATHS="$all" NPM_REJECTION=""
  eval "$block"
  [ "${#GUARD_STATUS_DESC}" -le 140 ] || return 1
  [ "$GUARD_STATUS_DESC" = "Unsupported dependency file: ...${long: -60} (+1500 more). Manual review required." ] || return 1

  # npm rejection
  NPM_REJECTION='`the reason`'
  eval "$block"
  [ "${#GUARD_STATUS_DESC}" -le 140 ] || return 1
  [[ "$GUARD_STATUS_DESC" == "Dependency parser rejected ...${long: -60} (+1500 more)."* ]] || return 1

  # zero rows
  UNSUPPORTED_PATHS="" NPM_REJECTION=""
  eval "$block"
  [ "${#GUARD_STATUS_DESC}" -le 140 ] || return 1
  [[ "$GUARD_STATUS_DESC" == "No dependencies extracted from ...${long: -60} (+1500 more)."* ]] || return 1

  # unresolved FROM, sole Dockerfile-type path
  long_df="$(printf 'a%.0s' $(seq 1 250))/deep/nested/Containerfile"
  DEPS_TSV=$'${BASE}\t-\tdocker' TOUCHED_PATHS="$long_df" EFFECTIVE_TOUCHED="$long_df"
  eval "$block"
  [ "${#GUARD_STATUS_DESC}" -le 140 ] || return 1
  [ "$GUARD_STATUS_DESC" = "Unresolved FROM line in ...${long_df: -60}. Manual review required." ] || return 1
}

@test "status: printf-special characters in a path stay literal" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS='we%dird\x41%s/Pipfile'
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  eval "$block"
  [ "$GUARD_STATUS_DESC" = 'Unsupported dependency file: we%dird\x41%s/Pipfile. Manual review required.' ]
}

@test "status: blank lines in the path list are neither named nor counted" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="Pipfile"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS=$'\nPipfile\n\n'
  eval "$block"
  [ "$GUARD_STATUS_DESC" = "Unsupported dependency file: Pipfile. Manual review required." ]
}

@test "status: a long non-ASCII path stays within 140 characters" {
  block=$(extract_guard_block .github/workflows/dependency-safety.yml)
  DEPS_TSV=""
  TOUCHED_PATHS="$(printf 'é%.0s' $(seq 1 100))/Pipfile"
  EFFECTIVE_TOUCHED="$TOUCHED_PATHS"
  UNSUPPORTED_PATHS="$TOUCHED_PATHS"
  eval "$block"
  [ -n "$GUARD_STATUS_DESC" ] || return 1
  [ "${#GUARD_STATUS_DESC}" -le 140 ]
}
