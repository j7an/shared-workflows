#!/usr/bin/env bash
# pyproject-bump-extract.sh — diff-aware extractor for pyproject.toml bump-only edits.
#
# Owns all pyproject.toml diff semantics for the dependency-cooldown/safety
# workflows. Recognizes the narrow set of bump shapes Dependabot emits for
# uv/poetry ecosystems and emits either extracted dep rows (mode=deps) or
# the paths it proved are bump-only (mode=cleared-paths). Files with any
# unparseable changed line (build-system edits, new-dep additions, marker
# changes, etc.) are disqualified and left unsupported so the existing
# fail-loud guard fires.
#
# Input:  unified diff on stdin
# Flag:   --mode=deps  OR  --mode=cleared-paths  (exactly one, required)
# Output (deps):          TSV <name>\t<version>\tpypi, sorted by name, deduped
# Output (cleared-paths): newline-delimited pyproject.toml paths, sorted, deduped
# Exit:   0 on success (possibly zero rows / zero paths)
#         2 on malformed input, missing --mode, unknown mode, or repeated --mode
#
# Bash 3.2 compatible: no `declare -A`, no `mapfile`/`readarray`. Dedup uses a
# newline-delimited string sentinel, matching scripts/extract-deps.sh.
#
# See docs/superpowers/specs/2026-05-23-pyproject-toml-parser-design.md.

set -euo pipefail

MODE=""
for arg in "$@"; do
  case "$arg" in
    --mode=deps|--mode=cleared-paths)
      if [ -n "$MODE" ]; then
        echo "pyproject-bump-extract.sh: --mode specified more than once" >&2
        exit 2
      fi
      MODE="${arg#--mode=}"
      ;;
    *)
      echo "pyproject-bump-extract.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "pyproject-bump-extract.sh: --mode=deps or --mode=cleared-paths required" >&2
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
  echo "pyproject-bump-extract.sh: input is not a unified diff" >&2
  exit 2
fi

# --- Parser state ---
# Per-file (reset on each diff --git boundary):
current_path=""
current_basename=""
current_table=""        # "" | "project_other" | "project_optional_deps" | "dependency_groups"
                        # | "tool_uv" | "poetry_main" | "poetry_group" | "poetry_dev"
                        # | "build_system" | "other"
current_key=""          # array-opening key for tables where keys are dep arrays
verdict="clean"
file_rows=$'\n'

# Global:
out_deps_rows=()
out_cleared_paths=()
seen=$'\n'              # dedup sentinel "\npypi:<name>\n"

# Single pending tracker. Lifetime = exactly one line. If pending is set,
# the IMMEDIATELY NEXT line MUST be the matching + (same kind, same name,
# same skeleton). Anything else (other -, unmatched +, context, comment,
# header, hunk boundary, file boundary, EOF) disqualifies.
pending_kind=""         # "" | "pep508" | "poetry_keyval" | "poetry_inline"
pending_name=""
pending_skeleton=""     # entry with version-spec field substituted by sentinel
pending_minus_version=""

# --- Helpers ---

# extract_target_version "$spec" — §3.3.1. Prints target on stdout, returns 1 on disqualify.
extract_target_version() {
  local spec="$1" stripped
  spec="${spec#"${spec%%[![:space:]]*}"}"
  spec="${spec%"${spec##*[![:space:]]}"}"
  case "$spec" in *,*) return 1 ;; esac
  case "$spec" in
    \^*)    stripped="${spec#\^}" ;;
    \~=*)   stripped="${spec#~=}" ;;
    \~*)    stripped="${spec#~}" ;;
    \>=*)   stripped="${spec#>=}" ;;
    ==*)    stripped="${spec#==}" ;;
    \<*|\<=*|\>*|!=*) return 1 ;;
    *)      stripped="$spec" ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [[ "$stripped" =~ ^[0-9]+(\.[0-9]+)*((a|b|rc|alpha|beta)[0-9]*)?(\.post[0-9]+)?(\.dev[0-9]+)?$ ]]; then
    printf '%s' "$stripped"
    return 0
  fi
  return 1
}

# parse_pep508_entry "$content" — captures name/extras/version_spec/marker.
# Sets _pep_name, _pep_extras (with brackets, or empty), _pep_version_spec,
# _pep_marker (with leading ';', or empty). Returns 0/1.
parse_pep508_entry() {
  local content="$1" trimmed
  _pep_name=""; _pep_extras=""; _pep_version_spec=""; _pep_marker=""
  if [[ "$content" =~ ^[[:space:]]*\"([A-Za-z][A-Za-z0-9_.-]*)(\[[^]]*\])?([^\";]*)(;.*)?\"[[:space:]]*,?[[:space:]]*$ ]]; then
    _pep_name="${BASH_REMATCH[1]}"
    _pep_extras="${BASH_REMATCH[2]}"
    _pep_version_spec="${BASH_REMATCH[3]}"
    _pep_marker="${BASH_REMATCH[4]}"
    # Validate: non-empty version_spec must start with a PEP 508 operator.
    # Bare versions (e.g., "foo 1.0") are malformed PEP 508 and must not parse.
    trimmed="${_pep_version_spec#"${_pep_version_spec%%[![:space:]]*}"}"
    if [ -n "$trimmed" ]; then
      case "$trimmed" in
        \^*|\~=*|\~*|\>=*|==*|\<=*|\<*|\>*|!=*) ;;
        *) return 1 ;;
      esac
    fi
    return 0
  fi
  return 1
}

# parse_poetry_keyval "$value" — for "spec" form. Sets _poetry_keyval_version.
parse_poetry_keyval() {
  local value="$1"
  _poetry_keyval_version=""
  if [[ "$value" =~ ^[[:space:]]*\"([^\"]*)\"[[:space:]]*$ ]]; then
    _poetry_keyval_version="${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# parse_poetry_inline "$value" — for { version = "spec", ... } form.
# Sets _poetry_inline_version and _poetry_inline_skeleton (version VALUE
# substituted, surrounding whitespace preserved). Requires `version` to be
# preceded by start-of-string, comma, or whitespace so `subversion` does
# not match (Bug 2). Preserves original whitespace around `=` so
# reformatting that changes spacing is caught (Bug 4).
parse_poetry_inline() {
  local value="$1" inner
  _poetry_inline_version=""; _poetry_inline_skeleton=""
  if [[ "$value" =~ ^[[:space:]]*\{(.*)\}[[:space:]]*$ ]]; then
    inner="${BASH_REMATCH[1]}"
    if [[ "$inner" =~ (^|[,[:space:]])version[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
      _poetry_inline_version="${BASH_REMATCH[2]}"
      _poetry_inline_skeleton=$(printf '%s' "$inner" | sed -E 's/(^|[,[:space:]])(version[[:space:]]*=[[:space:]]*)"[^"]*"/\1\2"__VER__"/')
      return 0
    fi
  fi
  return 1
}

# extract_operator "$spec" — returns the operator portion on stdout.
# "^", "~=", "~", ">=", "==" → printed verbatim; bare version → empty string.
# Unsupported operators (<, <=, >, !=) → return 1 (caller treats as disqualify).
extract_operator() {
  local spec="$1" trimmed
  trimmed="${spec#"${spec%%[![:space:]]*}"}"
  case "$trimmed" in
    \^*)   printf '%s' '^' ;;
    \~=*)  printf '%s' '~=' ;;
    \~*)   printf '%s' '~' ;;
    \>=*)  printf '%s' '>=' ;;
    ==*)   printf '%s' '==' ;;
    \<=*|\<*|\>*|!=*) return 1 ;;
    *)     printf '%s' '' ;;
  esac
  return 0
}

emit_bump() {
  local name="$1" plus_spec="$2" minus_spec="$3" target plus_op minus_op
  if [ "$plus_spec" = "$minus_spec" ]; then verdict="disqualified"; return; fi
  plus_op=$(extract_operator "$plus_spec") || { verdict="disqualified"; return; }
  minus_op=$(extract_operator "$minus_spec") || { verdict="disqualified"; return; }
  if [ "$plus_op" != "$minus_op" ]; then verdict="disqualified"; return; fi
  target=$(extract_target_version "$plus_spec") || { verdict="disqualified"; return; }
  extract_target_version "$minus_spec" >/dev/null || { verdict="disqualified"; return; }
  file_rows="${file_rows}${name}	${target}	pypi"$'\n'
}

clear_pending() {
  pending_kind=""
  pending_name=""
  pending_skeleton=""
  pending_minus_version=""
}

flush_pending_as_disqualified() {
  if [ -n "$pending_kind" ]; then
    verdict="disqualified"
    clear_pending
  fi
}

flush_file() {
  flush_pending_as_disqualified
  if [ -z "$current_basename" ] || [ "$current_basename" != "pyproject.toml" ]; then
    return
  fi
  if [ "$verdict" = "clean" ]; then
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      local name="${row%%	*}"
      local key="pypi:$name"
      case "$seen" in *$'\n'"$key"$'\n'*) continue ;; esac
      seen="${seen}${key}"$'\n'
      out_deps_rows+=("$row")
    done <<< "$file_rows"
    out_cleared_paths+=("$current_path")
  fi
}

reset_file_state() {
  current_table=""
  current_key=""
  verdict="clean"
  file_rows=$'\n'
  clear_pending
}

# --- Main parse loop ---
while IFS= read -r line; do
  line="${line%$'\r'}"

  # File boundary.
  if [[ "$line" =~ ^diff[[:space:]]--git[[:space:]]a/([^[:space:]]+)[[:space:]]b/([^[:space:]]+) ]]; then
    flush_file
    current_path="${BASH_REMATCH[2]}"
    current_basename="${current_path##*/}"
    reset_file_state
    continue
  fi

  [[ "$line" == +++* ]] && continue
  [[ "$line" == ---* ]] && continue

  if [[ "$line" =~ ^@@ ]]; then
    flush_pending_as_disqualified
    current_table=""
    current_key=""
    continue
  fi

  [ "$current_basename" != "pyproject.toml" ] && continue
  [ "$verdict" = "disqualified" ] && continue

  prefix="${line:0:1}"
  content="${line:1}"

  # ---------------- Centralized pending consumption ----------------
  # If pending is set, this line MUST be the matching + (same kind/name/skeleton)
  # or the file is disqualified. No other line type may consume or pass through
  # pending state.
  if [ -n "$pending_kind" ]; then
    consumed=false
    if [ "$prefix" = "+" ]; then
      case "$pending_kind" in
        pep508)
          if parse_pep508_entry "$content"; then
            plus_skeleton="${_pep_name}${_pep_extras}__VER__${_pep_marker}"
            if [ "$_pep_name" = "$pending_name" ] && [ "$plus_skeleton" = "$pending_skeleton" ]; then
              emit_bump "$_pep_name" "$_pep_version_spec" "$pending_minus_version"
              consumed=true
            fi
          fi
          ;;
        poetry_keyval)
          if [[ "$content" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            plus_key="${BASH_REMATCH[1]}"
            plus_value="${BASH_REMATCH[2]}"
            if [ "$plus_key" = "$pending_name" ] && parse_poetry_keyval "$plus_value"; then
              emit_bump "$plus_key" "$_poetry_keyval_version" "$pending_minus_version"
              consumed=true
            fi
          fi
          ;;
        poetry_inline)
          if [[ "$content" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            plus_key="${BASH_REMATCH[1]}"
            plus_value="${BASH_REMATCH[2]}"
            if [ "$plus_key" = "$pending_name" ] && parse_poetry_inline "$plus_value"; then
              if [ "$_poetry_inline_skeleton" = "$pending_skeleton" ]; then
                emit_bump "$plus_key" "$_poetry_inline_version" "$pending_minus_version"
                consumed=true
              fi
            fi
          fi
          ;;
      esac
    fi
    clear_pending
    if [ "$consumed" = "false" ]; then
      verdict="disqualified"
    fi
    continue
  fi
  # ---------------- End pending consumption ----------------

  # Comment / whitespace allowance anywhere (§3.4 rule 2).
  if [[ "$content" =~ ^[[:space:]]*# ]]; then continue; fi
  if [[ "$content" =~ ^[[:space:]]*$ ]]; then continue; fi

  # Table header detection.
  if [[ "$content" =~ ^[[:space:]]*\[([^]]+)\] ]]; then
    header="${BASH_REMATCH[1]}"
    case "$header" in
      project)                          current_table="project_other"; current_key="" ;;
      project.optional-dependencies)    current_table="project_optional_deps"; current_key="" ;;
      dependency-groups)                current_table="dependency_groups"; current_key="" ;;
      tool.uv)                          current_table="tool_uv"; current_key="" ;;
      tool.poetry.dependencies)         current_table="poetry_main"; current_key="" ;;
      tool.poetry.dev-dependencies)     current_table="poetry_dev"; current_key="" ;;
      build-system)                     current_table="build_system"; current_key="" ;;
      *)
        case "$header" in
          tool.poetry.group.*.dependencies) current_table="poetry_group"; current_key="" ;;
          *) current_table="other"; current_key="" ;;
        esac
        ;;
    esac
    # Changed table header = structural change → disqualify.
    if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
    continue
  fi

  # Key = ... line — per-table routing.
  if [[ "$content" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    case "$current_table" in
      project_other)
        if [ "$key" = "dependencies" ]; then
          # `dependencies = [` on +/- = structural change.
          if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; continue; fi
          current_key="dependencies"
        else
          # Any other [project] key on +/- (name, version, description, ...) disqualifies.
          current_key=""
          if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
        fi
        ;;
      project_optional_deps|dependency_groups)
        # Adding/renaming an extras key or dep group is structural.
        if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; continue; fi
        current_key="$key"
        ;;
      tool_uv)
        case "$key" in
          constraint-dependencies|override-dependencies)
            if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; continue; fi
            current_key="$key"
            ;;
          *)
            current_key=""
            if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
            ;;
        esac
        ;;
      poetry_main|poetry_group|poetry_dev)
        if [ "$key" = "python" ]; then
          if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
          continue
        fi
        # String form? Try first.
        if parse_poetry_keyval "$value"; then
          if [ "$prefix" = "-" ]; then
            pending_kind="poetry_keyval"
            pending_name="$key"
            pending_skeleton=""
            pending_minus_version="$_poetry_keyval_version"
            continue
          fi
          if [ "$prefix" = "+" ]; then
            # Unmatched + (no preceding -) → new-dep addition → disqualify.
            verdict="disqualified"
            continue
          fi
          # Context line: nothing.
          continue
        fi
        # Inline-table form?
        if parse_poetry_inline "$value"; then
          if [ "$prefix" = "-" ]; then
            pending_kind="poetry_inline"
            pending_name="$key"
            pending_skeleton="$_poetry_inline_skeleton"
            pending_minus_version="$_poetry_inline_version"
            continue
          fi
          if [ "$prefix" = "+" ]; then
            verdict="disqualified"
            continue
          fi
          continue
        fi
        # Unrecognized poetry value form on a changed line → disqualify
        # (git URL, path, editable, etc.).
        if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
        ;;
      build_system|other)
        if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
        ;;
    esac
    continue
  fi

  # PEP 508 string-in-array entry.
  if parse_pep508_entry "$content"; then
    # Positively-established array context required (Blocker 3).
    in_array=false
    case "$current_table" in
      project_other)
        [ "$current_key" = "dependencies" ] && in_array=true
        ;;
      project_optional_deps|dependency_groups)
        [ -n "$current_key" ] && in_array=true
        ;;
      tool_uv)
        case "$current_key" in
          constraint-dependencies|override-dependencies) in_array=true ;;
        esac
        ;;
    esac
    if [ "$in_array" = "false" ]; then
      if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
      continue
    fi
    if [ "$prefix" = "-" ]; then
      pending_kind="pep508"
      pending_name="$_pep_name"
      pending_skeleton="${_pep_name}${_pep_extras}__VER__${_pep_marker}"
      pending_minus_version="$_pep_version_spec"
      continue
    fi
    if [ "$prefix" = "+" ]; then
      # Unmatched + (no preceding -) → new-dep addition → disqualify.
      verdict="disqualified"
      continue
    fi
    continue
  fi

  # Closing `]` of an array. On +/- this is reformatting/structural → disqualify.
  # On a context line, the array we were tracking has closed → reset current_key
  # so subsequent PEP 508-shaped lines do not inherit dependency-array context
  # (any later entries need fresh context to re-establish in_array).
  if [[ "$content" =~ ^[[:space:]]*\] ]]; then
    if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
    current_key=""
    continue
  fi

  # Anything else changed in pyproject.toml → disqualify.
  if [ "$prefix" = "+" ] || [ "$prefix" = "-" ]; then verdict="disqualified"; fi
done <<< "$input"

flush_file

if [ "$MODE" = "deps" ]; then
  if [ ${#out_deps_rows[@]} -gt 0 ]; then
    printf '%s\n' "${out_deps_rows[@]}" | sort -t$'\t' -k1,1 -u
  fi
else
  if [ ${#out_cleared_paths[@]} -gt 0 ]; then
    printf '%s\n' "${out_cleared_paths[@]}" | sort -u
  fi
fi
