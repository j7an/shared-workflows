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

# emit_tier2 <name> <version>
# Keyed on name@version for the same reason as emit_tier1 (§6.4).
emit_tier2() {
  local key="$1@$2"
  case "$seen_tier2" in
    *$'\n'"$key"$'\n'*) return 0 ;;
  esac
  seen_tier2="${seen_tier2}${key}"$'\n'
  tier2_rows+=("$1"$'\t'"$2"$'\t'"npm")
}

# split_package_key <'name@version'> — sets _pkg_name and _pkg_version.
# Scoped names start with '@', so the split is on the LAST '@'.
split_package_key() {
  local key="$1"
  _pkg_name="${key%@*}"
  _pkg_version="${key##*@}"
  [ -n "$_pkg_name" ] && [ -n "$_pkg_version" ]
}

# Lifecycle-script keys. Corroboration already excludes these structurally —
# a lifecycle key can never appear in an importers-derived dependency set —
# but the denylist makes the security property visible in the code rather
# than implied.
#
# Lifecycle script names ONLY. `version` and `dependencies` were removed: there
# is a real npm package named `version`, and denylisting it would reject a
# legitimate bump. A denylist must not overlap the namespace it sits beside.
LIFECYCLE_KEYS=$'\npreinstall\ninstall\npostinstall\npreprepare\nprepare\npostprepare\nprepublish\nprepublishOnly\npublish\npostpublish\nprepack\npostpack\npreuninstall\nuninstall\npostuninstall\npreversion\npostversion\n'

# is_valid_range <specifier> — npm version-range grammar. A shell command is
# not a range, which is what keeps `"postinstall": "curl … | sh"` out.
#
# The grammar must accept everything npm permits, or it becomes a
# false-positive generator that red-gates real manifests on unrelated bumps.
# Verified against live registry data: eslint declares `"jiti": "*"`, and vite
# declares `"esbuild": "^0.27.0 || ^0.28.0"` and
# `"@types/node": "^20.19.0 || >=22.12.0"`.
is_valid_range() {
  local spec="$1" part rest
  # Protocol forms are whole-string.
  case "$spec" in
    workspace:*|catalog:*|npm:*) return 0 ;;
  esac
  # `||` unions: every alternative must itself be a valid range.
  case "$spec" in
    *\|\|*)
      rest="$spec"
      while [ -n "$rest" ]; do
        part="${rest%%\|\|*}"
        is_valid_simple_range "$part" || return 1
        [ "$part" = "$rest" ] && break
        rest="${rest#*\|\|}"
      done
      return 0
      ;;
  esac
  is_valid_simple_range "$spec"
}

# is_valid_simple_range <specifier> — one alternative of a range union.
# Accepts space-joined intersections (">=1.0.0 <2.0.0") and hyphen ranges
# ("1.2.3 - 2.3.4") by validating each whitespace-separated token.
#
# GLOBBING MUST BE OFF around the word-split loop. With globbing on, an
# unquoted `$spec` of `*` is expanded against the working directory, so the
# bare `*` range (eslint declares `"jiti": "*"`) is accepted or rejected
# depending on whether the cwd happens to contain files. That makes the
# result environment-dependent — the test suite would pass locally and fail
# in CI, or vice versa. Verified: without `set -f`, `*` is rejected from a
# populated directory and accepted from an empty one.
is_valid_simple_range() {
  local spec="$1" tok rc=0 restore_glob=0
  # Trim.
  spec="${spec#"${spec%%[![:space:]]*}"}"
  spec="${spec%"${spec##*[![:space:]]}"}"
  [ -z "$spec" ] && return 1
  case "$-" in *f*) ;; *) restore_glob=1; set -f ;; esac
  for tok in $spec; do
    case "$tok" in
      -) continue ;;                 # hyphen-range separator
      \*|x|X) continue ;;            # bare wildcard
    esac
    # Comparator/caret/tilde prefix, then a (possibly partial, possibly
    # wildcarded) version with optional prerelease/build metadata.
    if ! [[ "$tok" =~ ^(\^|~\>?|\>=|\<=|\>|\<|=|v)?[0-9]+(\.([0-9]+|[xX\*]))*([-+][0-9A-Za-z.-]+)?$ ]]; then
      rc=1
      break
    fi
  done
  # Restore on every exit path — a bare `return 1` inside the loop would leave
  # globbing disabled for the rest of the script.
  [ "$restore_glob" -eq 1 ] && set +f
  return "$rc"
}

manifest_verdict="clean"
minus_names=$'\n'
plus_names=$'\n'

disqualify_manifest() {
  manifest_verdict="disqualified"
  echo "npm-bump-extract.sh: $1" >&2
}

# --- Pass 2: manifests ---
pass2_manifests() {
  local line path kind name spec prefix
  local in_manifest=0 current=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^diff[[:space:]]--git[[:space:]]a/([^[:space:]]+)[[:space:]]b/([^[:space:]]+) ]]; then
      path="${BASH_REMATCH[2]}"
      kind=$(classify_path "$path")
      if [ "$kind" = "manifest" ]; then
        in_manifest=1
        current="$path"
      else
        in_manifest=0
      fi
      continue
    fi
    [ "$in_manifest" -eq 1 ] || continue
    [[ "$line" == +++* ]] && continue
    [[ "$line" == ---[[:space:]]* ]] && continue
    [[ "$line" =~ ^@@ ]] && continue
    # Only changed lines are judged; context lines are inert.
    [[ "$line" =~ ^[+-] ]] || continue

    if ! [[ "$line" =~ ^([+-])[[:space:]]*\"([^\"]+)\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"[[:space:]]*,?[[:space:]]*$ ]]; then
      disqualify_manifest "$current: unrecognized changed line: ${line}"
      continue
    fi
    prefix="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    spec="${BASH_REMATCH[3]}"

    case "$LIFECYCLE_KEYS" in
      *$'\n'"$name"$'\n'*)
        disqualify_manifest "$current: lifecycle key changed: $name"
        continue
        ;;
    esac

    if ! is_valid_range "$spec"; then
      disqualify_manifest "$current: value is not a valid npm range: \"$name\": \"$spec\""
      continue
    fi

    case "$corroborate" in
      *$'\n'"$name"$'\n'*) ;;
      *)
        disqualify_manifest "$current: \"$name\" changed with no matching lockfile entry"
        continue
        ;;
    esac

    # Record the side this name appeared on, scoped to the file. Duplicates on
    # the same side mean the same key changed twice, which is malformed.
    if [ "$prefix" = "-" ]; then
      case "$minus_names" in
        *$'\n'"$current|$name"$'\n'*)
          disqualify_manifest "$current: duplicate removed key: $name"
          continue
          ;;
      esac
      minus_names="${minus_names}${current}|${name}"$'\n'
    else
      case "$plus_names" in
        *$'\n'"$current|$name"$'\n'*)
          disqualify_manifest "$current: duplicate added key: $name"
          continue
          ;;
      esac
      plus_names="${plus_names}${current}|${name}"$'\n'
    fi
  done <<< "$input"

  # Pairing check (spec §6.2). Every changed dependency must appear on BOTH
  # sides — a replacement. An unmatched `+` is a dependency ADDED and an
  # unmatched `-` is one REMOVED; both are unusual shapes for a Dependabot
  # version-update PR and get human review. A new package entering the tree
  # through a dependency-safety PR is the typosquat vector, and a freshly
  # published malicious package has no advisories yet, so it scans clean.
  local entry
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$plus_names" in
      *$'\n'"$entry"$'\n'*) ;;
      *) disqualify_manifest "${entry%%|*}: dependency removed without replacement: ${entry##*|}" ;;
    esac
  done <<< "$(printf '%s' "$minus_names")"

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$minus_names" in
      *$'\n'"$entry"$'\n'*) ;;
      *) disqualify_manifest "${entry%%|*}: dependency added without replacement: ${entry##*|}" ;;
    esac
  done <<< "$(printf '%s' "$plus_names")"
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
      # Package-key line. A legitimate version replacement changes the key AND
      # its metadata on the same side, which is why the side is still recorded.
      if [[ "$line" =~ ^([+\ -])[[:space:]]+\'?([^\'[:space:]]+)\'?:[[:space:]]*$ ]]; then
        tier2_key_prefix="${BASH_REMATCH[1]}"
        if [ "$tier2_key_prefix" = "+" ]; then
          if split_package_key "${BASH_REMATCH[2]}"; then
            emit_tier2 "$_pkg_name" "$_pkg_version"
          else
            disqualify_lock "unparseable package key under packages:: ${BASH_REMATCH[2]}"
          fi
        fi
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
  if [ ${#tier2_rows[@]} -gt "$TIER2_MAX_ENTRIES" ]; then
    disqualify_lock "tier-2 entries (${#tier2_rows[@]}) exceed cap of ${TIER2_MAX_ENTRIES}"
  fi
  return 0
}

pass1_lock
pass2_manifests

# A manifest cannot be corroborated without a parseable lockfile, so a
# disqualified or absent lockfile poisons every manifest in the diff.
if [ "$lock_verdict" != "clean" ]; then
  manifest_verdict="disqualified"
fi
if [ "$manifest_verdict" != "clean" ]; then
  lock_verdict="disqualified"
fi

case "$MODE" in
  deps)
    # `sort -u` over the whole line. NEVER `sort -k1,1 -u` — see Task 5.
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
    if [ "$lock_verdict" = "clean" ]; then
      {
        [ -n "$lock_path" ] && printf '%s\n' "$lock_path"
        printf '%s' "$manifest_paths" | sed '/^$/d'
      } | sort -u
    fi
    ;;
esac

exit 0
