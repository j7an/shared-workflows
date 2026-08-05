#!/usr/bin/env bash
# check-release-age.sh — read dep TSV on stdin, emit verdict TSV on stdout
#
# Schema:
#   in:  <name>\t<version>\t<ecosystem>
#   out: <name>\t<version>\t<ecosystem>\t<published_iso>\t<age_days>\t<verdict>\t<reason>
#
# Ecosystems: actions (GitHub releases API), pypi (PyPI JSON API),
# npm (deps.dev stable v3).
#
# Verdicts: pass | fail | error
# Exit: always 0; failures are per-row.
#
# Bash 3.2 compatible (macOS system bash).

set -uo pipefail

: "${COOLDOWN_DAYS:?COOLDOWN_DAYS env var is required}"
: "${NOW_EPOCH:=$(date +%s)}"

# iso_to_epoch <iso> — print unix epoch on stdout, return 1 on parse failure.
# Handles both GitHub ("2026-03-29T12:00:00Z") and PyPI ("2026-03-29T12:00:00")
# ISO variants across GNU and BSD date.
iso_to_epoch() {
  local iso="$1"
  # GNU date: accepts the ISO string as-is (with or without Z).
  date -u -d "$iso" +%s 2>/dev/null && return 0
  # GNU date: append Z for naive PyPI upload_time.
  date -u -d "${iso}Z" +%s 2>/dev/null && return 0
  # BSD date (macOS): strip trailing Z and parse via -jf.
  local stripped="${iso%Z}"
  date -u -jf '%Y-%m-%dT%H:%M:%S' "$stripped" +%s 2>/dev/null && return 0
  return 1
}

# fetch_github <owner> <repo> <version> — print published_at ISO on stdout, return 1 on failure.
fetch_github() {
  local owner="$1" repo="$2" version="$3"
  if [ -n "${AGE_FIXTURE_DIR:-}" ]; then
    local fx="$AGE_FIXTURE_DIR/github/$owner/$repo/releases/tags/v$version.json"
    [ -f "$fx" ] || return 1
    jq -r '.published_at // empty' "$fx"
    return 0
  fi
  local resp
  if ! resp=$(gh api "repos/$owner/$repo/releases/tags/v$version" 2>/dev/null); then
    sleep 2
    if ! resp=$(gh api "repos/$owner/$repo/releases/tags/v$version" 2>/dev/null); then
      return 1
    fi
  fi
  printf '%s' "$resp" | jq -r '.published_at // empty'
}

# fetch_pypi <pkg> <version> — print "<upload_time>\t<yanked_bool>" on stdout, return 1 on failure.
fetch_pypi() {
  local pkg="$1" version="$2"
  local upload yanked
  if [ -n "${AGE_FIXTURE_DIR:-}" ]; then
    local fx="$AGE_FIXTURE_DIR/pypi/$pkg/$version.json"
    [ -f "$fx" ] || return 1
    upload=$(jq -r '.urls[0].upload_time // empty' "$fx")
    yanked=$(jq -r '.urls[0].yanked // false' "$fx")
    printf '%s\t%s\n' "$upload" "$yanked"
    return 0
  fi
  local resp
  if ! resp=$(curl -sf --max-time 30 "https://pypi.org/pypi/$pkg/$version/json" 2>/dev/null); then
    sleep 2
    if ! resp=$(curl -sf --max-time 30 "https://pypi.org/pypi/$pkg/$version/json" 2>/dev/null); then
      return 1
    fi
  fi
  upload=$(printf '%s' "$resp" | jq -r '.urls[0].upload_time // empty')
  yanked=$(printf '%s' "$resp" | jq -r '.urls[0].yanked // false')
  printf '%s\t%s\n' "$upload" "$yanked"
}

# urlencode_segment <value> — percent-encode one URL path segment.
# jq's @uri leaves only the unreserved set (A-Za-z0-9-_.~) intact, so scope
# separators ('@', '/'), traversal sequences, and query/fragment delimiters are
# all neutralised. Applied to the version as well as the name: curl normalises
# '..' segments client-side, so an unencoded '/' in a version string would let
# one package's age be reported for another.
urlencode_segment() {
  jq -rn --arg s "$1" '$s|@uri'
}

# fetch_npm <pkg> <version> — print "<publishedAt>\t<isDeprecated>" on stdout,
# return 1 on failure. Source is deps.dev stable v3: one ~1 KB response
# carries both facts, where the npm registry needs a multi-MB packument for
# the timestamp plus a second request for deprecation.
fetch_npm() {
  local pkg="$1" version="$2"
  local published deprecated
  if [ -n "${AGE_FIXTURE_DIR:-}" ]; then
    local fx="$AGE_FIXTURE_DIR/npm/$pkg/$version.json"
    [ -f "$fx" ] || return 1
    published=$(jq -r '.publishedAt // empty' "$fx")
    deprecated=$(jq -r '.isDeprecated // false' "$fx")
    printf '%s\t%s\n' "$published" "$deprecated"
    return 0
  fi
  local url resp
  url="https://api.deps.dev/v3/systems/npm/packages/$(urlencode_segment "$pkg")/versions/$(urlencode_segment "$version")"
  if ! resp=$(curl -sf --max-time 30 "$url" 2>/dev/null); then
    sleep 2
    if ! resp=$(curl -sf --max-time 30 "$url" 2>/dev/null); then
      return 1
    fi
  fi
  published=$(printf '%s' "$resp" | jq -r '.publishedAt // empty')
  deprecated=$(printf '%s' "$resp" | jq -r '.isDeprecated // false')
  printf '%s\t%s\n' "$published" "$deprecated"
}

# emit name version ecosystem published age verdict reason
emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

while IFS=$'\t' read -r name version ecosystem || [ -n "${name:-}" ]; do
  [ -z "${name:-}" ] && continue

  # Escape hatch: COOLDOWN_DAYS=0 → all pass without lookup.
  if [ "$COOLDOWN_DAYS" -eq 0 ]; then
    emit "$name" "$version" "$ecosystem" "-" "-" "pass" ""
    continue
  fi

  case "$ecosystem" in
    actions)
      owner="${name%%/*}"
      remainder="${name#*/}"
      repo="${remainder%%/*}"
      if ! iso=$(fetch_github "$owner" "$repo" "$version"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "tier-1-404"
        continue
      fi
      if [ -z "$iso" ]; then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "transient-failure"
        continue
      fi
      if ! pub_epoch=$(iso_to_epoch "$iso"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "parse-failure"
        continue
      fi
      age_days=$(( (NOW_EPOCH - pub_epoch) / 86400 ))
      if [ "$age_days" -ge "$COOLDOWN_DAYS" ]; then
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "pass" ""
      else
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "fail" ""
      fi
      ;;

    pypi)
      if ! result=$(fetch_pypi "$name" "$version"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "pypi-404"
        continue
      fi
      iso="${result%%$'\t'*}"
      yanked="${result##*$'\t'}"
      if [ -z "$iso" ]; then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "transient-failure"
        continue
      fi
      if ! pub_epoch=$(iso_to_epoch "$iso"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "parse-failure"
        continue
      fi
      age_days=$(( (NOW_EPOCH - pub_epoch) / 86400 ))
      if [ "$yanked" = "true" ]; then
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "fail" "yanked"
      elif [ "$age_days" -ge "$COOLDOWN_DAYS" ]; then
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "pass" ""
      else
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "fail" ""
      fi
      ;;

    npm)
      if ! result=$(fetch_npm "$name" "$version"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "npm-404"
        continue
      fi
      iso="${result%%$'\t'*}"
      deprecated="${result##*$'\t'}"
      if [ -z "$iso" ]; then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "transient-failure"
        continue
      fi
      if ! pub_epoch=$(iso_to_epoch "$iso"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "parse-failure"
        continue
      fi
      age_days=$(( (NOW_EPOCH - pub_epoch) / 86400 ))
      if [ "$deprecated" = "true" ]; then
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "fail" "deprecated"
      elif [ "$age_days" -ge "$COOLDOWN_DAYS" ]; then
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "pass" ""
      else
        emit "$name" "$version" "$ecosystem" "$iso" "$age_days" "fail" ""
      fi
      ;;

    *)
      emit "$name" "$version" "$ecosystem" "-" "-" "error" "unknown-ecosystem"
      ;;
  esac
done

exit 0
