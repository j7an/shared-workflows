#!/usr/bin/env bash
# check-release-age.sh — read dep TSV on stdin, emit verdict TSV on stdout
#
# Schema:
#   in:  <name>\t<version>\t<ecosystem>
#   out: <name>\t<version>\t<ecosystem>\t<published_iso>\t<age_days>\t<verdict>\t<reason>
#
# Ecosystems: actions (GitHub releases API), pypi (PyPI JSON API),
# npm (deps.dev stable v3), docker (image config `created` from the OCI
# registry API; newest across platforms).
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

# docker_registry_repo <name> — print "<host>\t<repo>" on stdout.
# A first path component containing '.' or ':' (or equal to 'localhost') is
# the registry host; otherwise the image lives on Docker Hub.
docker_registry_repo() {
  local name="$1" first rest host repo
  first="${name%%/*}"
  rest="${name#*/}"
  if [ "$first" != "$name" ] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = "localhost" ]; }; then
    host="$first"
    repo="$rest"
    if [ "$host" = "docker.io" ]; then
      host="registry-1.docker.io"
    fi
  else
    host="registry-1.docker.io"
    repo="$name"
  fi
  if [ "$host" = "registry-1.docker.io" ]; then
    repo="${repo#docker.io/}"
    case "$repo" in
      */*) ;;
      *) repo="library/$repo" ;;
    esac
  fi
  printf '%s\t%s\n' "$host" "$repo"
}

# registry_http <url> <body-file> <header-file> [header]... — one curl call;
# prints the HTTP status ("000" on network failure).
registry_http() {
  local url="$1" bfile="$2" hfile="$3" code
  shift 3
  local args=() h
  for h in "$@"; do
    args+=(-H "$h")
  done
  code=$(curl -sS --proto '=https' --proto-redir '=https' --max-time 30 -L -D "$hfile" -o "$bfile" -w '%{http_code}' ${args[@]+"${args[@]}"} "$url" 2>/dev/null) || code=000
  printf '%s' "${code:-000}"
}

# registry_get <host> <repo> <path> — print the response body on stdout.
# On failure return non-zero with the error reason on stdout.
# Fixture mode reads $AGE_FIXTURE_DIR/docker/<host>/<repo>/<path>.json.
registry_get() {
  local host="$1" repo="$2" path="$3"
  if [ -n "${AGE_FIXTURE_DIR:-}" ]; then
    local fx="$AGE_FIXTURE_DIR/docker/$host/$repo/$path.json"
    if [ ! -f "$fx" ]; then
      printf 'docker-404'
      return 1
    fi
    cat "$fx"
    return 0
  fi
  local url="https://$host/v2/$repo/$path"
  local accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  local tmp bfile hfile code attempt authz="" challenge realm service scope turl
  tmp=$(mktemp -d) || { printf 'transient-failure'; return 1; }
  bfile="$tmp/body"
  hfile="$tmp/hdr"
  attempt=0
  while :; do
    if [ -n "$authz" ]; then
      code=$(registry_http "$url" "$bfile" "$hfile" "Accept: $accept" "Authorization: Bearer $authz")
    else
      code=$(registry_http "$url" "$bfile" "$hfile" "Accept: $accept")
    fi
    case "$code" in
      2??)
        cat "$bfile"
        rm -rf "$tmp"
        return 0
        ;;
      401)
        if [ -n "$authz" ]; then
          rm -rf "$tmp"
          printf 'docker-auth-required'
          return 1
        fi
        challenge=$(grep -i '^www-authenticate:' "$hfile" 2>/dev/null | head -n 1 | tr -d '\r')
        realm=$(printf '%s' "$challenge" | sed -n 's/.*[Rr]ealm="\([^"]*\)".*/\1/p')
        service=$(printf '%s' "$challenge" | sed -n 's/.*[Ss]ervice="\([^"]*\)".*/\1/p')
        scope=$(printf '%s' "$challenge" | sed -n 's/.*[Ss]cope="\([^"]*\)".*/\1/p')
        case "$realm" in https://*) ;; *) realm="" ;; esac
        if [ -z "$realm" ]; then
          rm -rf "$tmp"
          printf 'docker-auth-required'
          return 1
        fi
        turl="$realm?service=$service&scope=$scope"
        code=$(registry_http "$turl" "$bfile" "$hfile")
        case "$code" in
          2??) authz=$(jq -r '.token // .access_token // empty' "$bfile" 2>/dev/null) ;;
          *) authz="" ;;
        esac
        if [ -z "$authz" ]; then
          rm -rf "$tmp"
          printf 'docker-auth-required'
          return 1
        fi
        ;;
      403)
        rm -rf "$tmp"
        printf 'docker-auth-required'
        return 1
        ;;
      404)
        rm -rf "$tmp"
        printf 'docker-404'
        return 1
        ;;
      429)
        rm -rf "$tmp"
        printf 'docker-rate-limited'
        return 1
        ;;
      *)
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 2 ]; then
          rm -rf "$tmp"
          printf 'transient-failure'
          return 1
        fi
        sleep "${AGE_RETRY_SLEEP:-2}"
        ;;
    esac
  done
}

# fetch_docker <name> <version> — print the newest image config `created`
# (YYYY-MM-DDTHH:MM:SSZ) on stdout. On failure return 1 with the reason on stdout.
# The reference is the digest when version carries a sha256, else the tag.
# For an index, every entry whose platform os is not "unknown" counts (this
# skips attestation manifests); the newest `created` across platforms wins.
# ponytail: one config fetch per platform (~9 manifest GETs for an 8-platform
# index against Docker Hub's anonymous 100 per 6 h). Switch to index
# org.opencontainers.image.created annotations if rate limits bite in practice.
fetch_docker() {
  local name="$1" version="$2"
  local hr host repo ref body digests d mbody cdigest cbody created
  local best_epoch="" best_iso="" ep re_frac='^(.*)\.[0-9]+Z$'
  hr=$(docker_registry_repo "$name")
  host="${hr%%$'\t'*}"
  repo="${hr#*$'\t'}"
  if [[ "$version" == *sha256:* ]]; then
    ref="sha256:${version##*sha256:}"
  else
    ref="$version"
  fi
  if ! body=$(registry_get "$host" "$repo" "manifests/$ref"); then
    printf '%s' "$body"
    return 1
  fi
  if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'parse-failure'
    return 1
  fi
  digests=""
  if printf '%s' "$body" | jq -e 'has("manifests")' >/dev/null 2>&1; then
    digests=$(printf '%s' "$body" | jq -r '(.manifests // [])[]? | select((.platform.os // "") != "unknown") | .digest // empty' 2>/dev/null)
    if [ -z "$digests" ]; then
      printf 'parse-failure'
      return 1
    fi
  else
    # Single manifest: its config is the one to read.
    mbody="$body"
    digests="-"
  fi
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if [ "$d" != "-" ]; then
      if ! mbody=$(registry_get "$host" "$repo" "manifests/$d"); then
        printf '%s' "$mbody"
        return 1
      fi
    fi
    cdigest=$(printf '%s' "$mbody" | jq -r '.config.digest // empty' 2>/dev/null)
    if [ -z "$cdigest" ]; then
      printf 'parse-failure'
      return 1
    fi
    if ! cbody=$(registry_get "$host" "$repo" "blobs/$cdigest"); then
      printf '%s' "$cbody"
      return 1
    fi
    created=$(printf '%s' "$cbody" | jq -r '.created // empty' 2>/dev/null)
    if [ -z "$created" ]; then
      printf 'parse-failure'
      return 1
    fi
    if [[ "$created" =~ $re_frac ]]; then
      created="${BASH_REMATCH[1]}Z"
    fi
    if ! ep=$(iso_to_epoch "$created"); then
      printf 'parse-failure'
      return 1
    fi
    if [ -z "$best_epoch" ] || [ "$ep" -gt "$best_epoch" ]; then
      best_epoch="$ep"
      best_iso="$created"
    fi
  done <<EOT
$digests
EOT
  printf '%s' "$best_iso"
}

# emit name version ecosystem published age verdict reason
emit() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# Test seam: source the functions above without running the loop.
[ "${CHECK_RELEASE_AGE_LIB:-}" = 1 ] && return 0 2>/dev/null

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

    docker)
      if [ "$version" = "-" ]; then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "docker-unresolved-reference"
        continue
      fi
      if ! iso=$(fetch_docker "$name" "$version"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "${iso:-transient-failure}"
        continue
      fi
      if ! pub_epoch=$(iso_to_epoch "$iso"); then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "parse-failure"
        continue
      fi
      # Sanity: reproducible-build images stamp created=1970 (or garbage in the
      # future); neither is a real build date, so never report them as pass.
      # 1356998400 = 2013-01-01T00:00:00Z (before Docker existed).
      if [ "$pub_epoch" -lt 1356998400 ] || [ "$pub_epoch" -gt "$NOW_EPOCH" ]; then
        emit "$name" "$version" "$ecosystem" "-" "-" "error" "implausible-timestamp"
        continue
      fi
      age_days=$(( (NOW_EPOCH - pub_epoch) / 86400 ))
      if [ "$age_days" -ge "$COOLDOWN_DAYS" ]; then
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
