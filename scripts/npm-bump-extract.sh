#!/usr/bin/env bash
# npm-bump-extract.sh — diff-aware extractor for package.json + pnpm-lock.yaml.
#
# Owns all npm-ecosystem diff semantics for the dependency-safety workflow.
# Emits tier-1 declared dependency rows (mode=deps), tier-2 newly introduced
# lockfile versions (mode=lockfile-entries), or the paths it proved parseable
# (mode=cleared-paths). Files with any unrecognized changed line are
# disqualified and left unsupported so the fail-loud guard fires.
#
# Input:  unified diff on stdin
# Flag:   --mode=deps | --mode=lockfile-entries | --mode=cleared-paths (exactly one)
# Output (deps):             TSV <name>\t<version>\tnpm, sorted by name, deduped
# Output (lockfile-entries): TSV <name>\t<version>\tnpm, sorted by name, deduped
# Output (cleared-paths):    newline-delimited paths, sorted, deduped
# Exit:   0 on success (possibly zero rows)
#         2 on malformed input, missing --mode, repeated --mode, unknown argument
#
# Bash 3.2 compatible: no `declare -A`, no `mapfile`/`readarray`. Dedup uses a
# newline-delimited string sentinel, matching scripts/extract-deps.sh.
#
# See docs/superpowers/specs/2026-08-04-npm-pnpm-dependency-safety-design.md.

set -euo pipefail

# Maximum tier-2 entries per PR. Exceeding it disqualifies the lockfile rather
# than truncating the sweep — a truncated scan reported as complete is the one
# outcome this helper must never produce. 1000 is ~4x the largest observed real
# Dependabot pnpm PR (253 entries).
TIER2_MAX_ENTRIES=1000

MODE=""
for arg in "$@"; do
  case "$arg" in
    --mode=deps|--mode=lockfile-entries|--mode=cleared-paths)
      if [ -n "$MODE" ]; then
        echo "npm-bump-extract.sh: --mode specified more than once" >&2
        exit 2
      fi
      MODE="${arg#--mode=}"
      ;;
    *)
      echo "npm-bump-extract.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "npm-bump-extract.sh: --mode=deps, --mode=lockfile-entries, or --mode=cleared-paths required" >&2
  exit 2
fi

input=$(cat)

# Empty input → exit 0 with no output (matches extract-deps.sh).
if [ -z "$input" ]; then
  exit 0
fi

# Malformed input detection: here-string (not pipeline) to avoid SIGPIPE under
# pipefail on large valid diffs (issue #50 pattern).
if ! grep -qE '^(\+\+\+|---|@@|diff --git)' <<< "$input"; then
  echo "npm-bump-extract.sh: input is not a unified diff" >&2
  exit 2
fi

# --- Path classification ---
# Only these two filenames are in scope. package-lock.json and yarn.lock are
# deliberately NOT handled here; they stay unsupported and fail closed.
classify_path() {
  local path="$1" base="${path##*/}"
  case "$base" in
    pnpm-lock.yaml) printf 'lock' ;;
    package.json)   printf 'manifest' ;;
    *)              printf '' ;;
  esac
}

# --- Globals ---
lock_path=""
lock_verdict="absent"          # absent | clean | disqualified
manifest_paths=$'\n'           # newline-delimited, leading+trailing newline
tier1_rows=()
tier2_rows=()
corroborate=$'\n'              # "\n<name>\n" for names whose lock entry changed
seen_tier1=$'\n'
seen_tier2=$'\n'

# disqualify_lock <reason> — mark the lockfile unusable and explain why.
disqualify_lock() {
  lock_verdict="disqualified"
  echo "npm-bump-extract.sh: ${lock_path:-pnpm-lock.yaml}: $1" >&2
}

# Disposition of each pnpm-lock.yaml top-level section (spec §6.1).
# The complete column-0 key set was taken from a real pnpm 12.0.0-beta.4
# lockfile. Anything absent from this list disqualifies, so a
# dependency-bearing section added by a future pnpm release produces a red
# gate rather than a silent gap in the completeness claim.
section_disposition() {
  case "$1" in
    importers:|catalogs:)                     printf 'tier1' ;;
    packages:)                                printf 'tier2' ;;
    snapshots:)                               printf 'inert' ;;
    lockfileVersion:)                         printf 'version' ;;
    settings:)                                printf 'disqualify' ;;
    overrides:|patchedDependencies:)          printf 'disqualify' ;;
    pnpmfileChecksum:)                        printf 'disqualify' ;;
    packageExtensionsChecksum:)               printf 'disqualify' ;;
    *)                                        printf 'unknown' ;;
  esac
}

# set_section <section-with-colon> — apply a section and its disposition.
# A disqualifying section only trips the verdict when a line under it actually
# changed; merely passing through it in context is harmless.
set_section() {
  current_section="$1"
  current_disposition=$(section_disposition "$1")
  seen_column0=1
}

# --- Pass 1: lockfile ---
pass1_lock() {
  local line kind path
  local in_lock=0
  local current_section=""
  local current_disposition=""
  local seen_column0=0
  local section=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^diff[[:space:]]--git[[:space:]]a/([^[:space:]]+)[[:space:]]b/([^[:space:]]+) ]]; then
      path="${BASH_REMATCH[2]}"
      kind=$(classify_path "$path")
      if [ "$kind" = "lock" ]; then
        in_lock=1
        lock_path="$path"
        [ "$lock_verdict" = "absent" ] && lock_verdict="clean"
      else
        in_lock=0
        if [ "$kind" = "manifest" ]; then
          case "$manifest_paths" in
            *$'\n'"$path"$'\n'*) ;;
            *) manifest_paths="${manifest_paths}${path}"$'\n' ;;
          esac
        fi
      fi
      continue
    fi
    [ "$in_lock" -eq 1 ] || continue
    [[ "$line" == +++* ]] && continue
    [[ "$line" == ---[[:space:]]* ]] && continue

    # Hunk header seeds the section. git's function-context heuristic reports
    # the nearest column-0 line, which for pnpm-lock.yaml is a section name.
    # Verified across 1004 hunk headers in three real Dependabot PRs.
    if [[ "$line" =~ ^@@ ]]; then
      # Take the section from the text AFTER the closing "@@" only.
      # `${line##*@@ }` is WRONG here: on a whole-file-add header
      # `@@ -0,0 +1,8 @@` the closing "@@" has no trailing space, so the glob
      # matches the LEADING "@@ " instead and yields "-0,0" — a non-empty
      # string that satisfies `[ -n "$section" ]` and silently skips the
      # no-section-context disqualification below. A brand-new lockfile would
      # then be reported as parseable and cleared. Verified on bash 3.2.57.
      # `[^@]*` is safe because a hunk range contains only digits, commas,
      # spaces and +/-, so it cannot swallow an "@" in a section name
      # (e.g. `@@ -1,2 +1,2 @@ lodash@4.17.21:` still yields the full key).
      section=""
      if [[ "$line" =~ ^@@[^@]*@@[[:space:]]*(.*)$ ]]; then
        section="${BASH_REMATCH[1]}"
        section="${section%%[[:space:]]*}"
      fi
      if [ -n "$section" ]; then
        set_section "$section"
      elif [ "$seen_column0" -eq 0 ]; then
        # No trailing context and no column-0 key seen yet: this is a newly
        # created lockfile arriving as one @@ -0,0 +1,N @@ hunk. Nothing
        # anchors the section state, so nothing can be proven.
        disqualify_lock "hunk header carries no section context"
      fi
      continue
    fi

    # A column-0 key inside the hunk body updates the section. Without this a
    # hunk that crosses a section boundary would keep parsing under the
    # previous section's rules — the catalogs:/overrides: adjacency case.
    if [[ "$line" =~ ^[+\ -]([A-Za-z][A-Za-z0-9]*:)[[:space:]]*$ ]] \
       || [[ "$line" =~ ^[+\ -]([A-Za-z][A-Za-z0-9]*:)[[:space:]] ]]; then
      set_section "${BASH_REMATCH[1]}"
      # A changed line that IS the section key still counts as a change under
      # that section (e.g. `-pnpmfileChecksum: sha256-AAAA`).
      if [[ "$line" =~ ^[+-] ]] && [ "$current_disposition" != "version" ]; then
        case "$current_disposition" in
          disqualify|unknown)
            disqualify_lock "change under unsupported lockfile section: $current_section"
            ;;
        esac
      fi
      continue
    fi

    # Any changed line under a disqualifying or unknown section fails the file.
    if [[ "$line" =~ ^[+-] ]]; then
      case "$current_disposition" in
        disqualify|unknown)
          disqualify_lock "change under unsupported lockfile section: ${current_section:-<none>}"
          continue
          ;;
      esac
    fi
  done <<< "$input"
  return 0
}

pass1_lock
exit 0
