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

# Lockfile format versions this parser understands. The parser keys on the
# declared format version and on structure, never on which pnpm produced the
# file — a future divergence must be a clean red gate, not a silent
# correctness bug.
SUPPORTED_LOCKFILE_VERSIONS=$'\n9.0\n'

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
  tier2_key_prefix=""
}

# base_version <version-string> — strip pnpm's peer-dependency suffix.
# "21.0.2(@types/node@22.19.9)" → "21.0.2"
base_version() {
  printf '%s' "${1%%(*}"
}

# note_corroborated <name> — record that this dependency's lock entry changed.
note_corroborated() {
  case "$corroborate" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  corroborate="${corroborate}${1}"$'\n'
}

# emit_tier1 <name> <version>
# Dedup key is name@version, NOT name. A pnpm workspace can resolve the same
# package at different versions in different importers; keying on name alone
# drops one of them and produces a scanned-claim over an unscanned version.
emit_tier1() {
  local key="$1@$2"
  case "$seen_tier1" in
    *$'\n'"$key"$'\n'*) return 0 ;;
  esac
  seen_tier1="${seen_tier1}${key}"$'\n'
  tier1_rows+=("$1"$'\t'"$2"$'\t'"npm")
}

# flush_entry — called at each entry/section/file boundary. Emits a tier-1 row
# when the base version changed, and records corroboration when either the
# specifier or the base version changed.
flush_entry() {
  local name="$1" minus="$2" plus="$3" spec="$4"
  [ -z "$name" ] && return 0
  local mb pb
  mb=$(base_version "$minus")
  pb=$(base_version "$plus")
  if [ -n "$plus" ] && [ "$mb" != "$pb" ]; then
    emit_tier1 "$name" "$pb"
    note_corroborated "$name"
  elif [ "$spec" -eq 1 ]; then
    note_corroborated "$name"
  fi
}

# --- Pass 1: lockfile ---
pass1_lock() {
  local line kind path
  local in_lock=0
  local current_section=""
  local current_disposition=""
  local seen_column0=0
  local section=""
  local declared=""
  local entry_name="" minus_ver="" plus_ver="" spec_changed=0
  local tier2_key_prefix=""
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

    # A document separator means sections may repeat, which the completeness
    # reasoning does not cover. Distinguished from the diff's own file header
    # (`--- a/path`), which always carries a path after the marker.
    if [[ "$line" =~ ^[+\ -]---$ ]]; then
      disqualify_lock "multi-document lockfile is not supported"
      continue
    fi

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
      # A format-version change is always visible in the diff, because a
      # changed line appears in a hunk by definition. When absent, the format
      # did not change. Safe to clobber BASH_REMATCH here: set_section above
      # already consumed the section capture.
      if [ "$current_disposition" = "version" ] \
         && [[ "$line" =~ ^\+lockfileVersion:[[:space:]]*\'?([0-9.]+)\'?[[:space:]]*$ ]]; then
        declared="${BASH_REMATCH[1]}"
        case "$SUPPORTED_LOCKFILE_VERSIONS" in
          *$'\n'"$declared"$'\n'*) ;;
          *) disqualify_lock "unsupported lockfileVersion: $declared" ;;
        esac
      fi
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

    if [ "$current_disposition" = "tier1" ]; then
      # Entry key line: a bare quoted-or-plain key with no value.
      if [[ "$line" =~ ^[+\ -][[:space:]]+\'?([^\':]+)\'?:[[:space:]]*$ ]]; then
        flush_entry "$entry_name" "$minus_ver" "$plus_ver" "$spec_changed"
        entry_name="${BASH_REMATCH[1]}"
        minus_ver=""; plus_ver=""; spec_changed=0
        continue
      fi
      if [[ "$line" =~ ^[+-][[:space:]]+specifier:[[:space:]]*(.*)$ ]]; then
        spec_changed=1
        continue
      fi
      if [[ "$line" =~ ^-[[:space:]]+version:[[:space:]]*(.*)$ ]]; then
        minus_ver="${BASH_REMATCH[1]}"
        continue
      fi
      if [[ "$line" =~ ^\+[[:space:]]+version:[[:space:]]*(.*)$ ]]; then
        plus_ver="${BASH_REMATCH[1]}"
        continue
      fi
      # Anything else that CHANGED under a tier-1 section is unaccounted for.
      # Falling through here is the §6.1 fail-open: it would clear the file with
      # an unexamined change. Context lines remain inert.
      if [[ "$line" =~ ^[+-] ]]; then
        disqualify_lock "unrecognized changed line under ${current_section}: ${line}"
      fi
      continue
    fi

    if [ "$current_disposition" = "tier2" ]; then
      # Package-key line. Record only which side it appeared on; emission is
      # Task 6's job.
      if [[ "$line" =~ ^([+\ -])[[:space:]]+\'?([^\'[:space:]]+)\'?:[[:space:]]*$ ]]; then
        tier2_key_prefix="${BASH_REMATCH[1]}"
        continue
      fi
      # A changed metadata line is only accounted for when the enclosing
      # package key changed on the SAME side. Under a CONTEXT key it means the
      # version did not move but its tarball did. Fail closed.
      if [[ "$line" =~ ^([+-]) ]]; then
        if [ "${BASH_REMATCH[1]}" != "$tier2_key_prefix" ]; then
          disqualify_lock "changed metadata for an unchanged package version under packages:: ${line}"
        fi
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
  flush_entry "$entry_name" "$minus_ver" "$plus_ver" "$spec_changed"
  return 0
}

pass1_lock

case "$MODE" in
  deps)
    # `sort -u` over the WHOLE line, never `sort -k1,1 -u`. The latter
    # deduplicates on the key field only, collapsing foo@1.0.0 and foo@2.0.0
    # into one row:
    #   $ printf 'foo\t1.0.0\tnpm\nfoo\t2.0.0\tnpm\n' | sort -t$'\t' -k1,1 -u
    #   foo	1.0.0	npm
    if [ "$lock_verdict" = "clean" ] && [ ${#tier1_rows[@]} -gt 0 ]; then
      printf '%s\n' "${tier1_rows[@]}" | sort -u
    fi
    ;;
  lockfile-entries)
    if [ "$lock_verdict" = "clean" ] && [ ${#tier2_rows[@]} -gt 0 ]; then
      printf '%s\n' "${tier2_rows[@]}" | sort -u
    fi
    ;;
  cleared-paths)
    if [ "$lock_verdict" = "clean" ] && [ -n "$lock_path" ]; then
      printf '%s\n' "$lock_path"
    fi
    ;;
esac

exit 0
