#!/usr/bin/env bash
# image-vuln-diff.sh — diff Trivy vulnerability results for two container images.
#
# Usage: image-vuln-diff.sh <db-version.json> <old.json> <new.json>
#   db-version.json  `trivy version --format json` output (reads
#                    .VulnerabilityDB.UpdatedAt)
#   old.json/new.json `trivy image --list-all-pkgs --format json` reports
# Env: IMAGE_DIFF_NOW  epoch seconds overriding the current time (tests only).
#
# Pure logic: jq is the only external tool; no network.
# Fail-closed: any failed check prints NOTHING on stdout, writes exactly one
# reason token as the first line of stderr, and exits 2.
#
# Output (stdout, one TSV row per delta entry, sorted, unique by
# (direction, class, id, pkg); empty output + exit 0 means no delta):
#   direction\tfixability\tclass\tid\tpkg\tinstalled\tfixed\tseverity
#     direction  introduced (in new only) | fixed (in old only)
#     fixability fixable | unfixed — from the new-side entry for introduced,
#                the old-side entry for fixed
#     class      os | lang (Trivy os-pkgs / lang-pkgs; other classes ignored)
#     fixed      FixedVersion, or - when Trivy omits it
# The delta keys on class + VulnerabilityID + PkgName only, so a shared entry
# whose InstalledVersion changed is not a delta row.
#
# Reason tokens (stderr line 1, exit 2):
#   usage                  wrong number of arguments
#   invalid-json           an input is missing, unparsable, lacks UpdatedAt, or has
#                          a non-array Vulnerabilities / an entry without string
#                          VulnerabilityID and PkgName
#   trivy-db-stale         DB UpdatedAt is more than 72 hours before now
#   platform-mismatch-old  old report's ImageConfig os/architecture is not
#   platform-mismatch-new  linux/amd64 (Trivy ignores --platform for
#                          single-platform images, so check the report)
#   no-packages-old        a report lists zero packages (sum of
#   no-packages-new        .Results[].Packages | length is 0)

set -u

STALE_HOURS=72

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

[ "$#" -eq 3 ] || fail usage
DB="$1"
OLD="$2"
NEW="$3"

for f in "$DB" "$OLD" "$NEW"; do
  jq -e . "$f" >/dev/null 2>&1 || fail invalid-json
done

# UpdatedAt has fractional seconds ("...:02.624123452Z"); strip them first.
UPDATED=$(jq -r '.VulnerabilityDB.UpdatedAt // empty
  | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' "$DB" 2>/dev/null) || fail invalid-json
[ -n "$UPDATED" ] || fail invalid-json

NOW="${IMAGE_DIFF_NOW:-$(date +%s)}"
[ $(( NOW - UPDATED )) -le $(( STALE_HOURS * 3600 )) ] || fail trivy-db-stale

for side in old new; do
  if [ "$side" = old ]; then f="$OLD"; else f="$NEW"; fi
  jq -e '.Metadata.ImageConfig.os == "linux"
         and .Metadata.ImageConfig.architecture == "amd64"' "$f" >/dev/null 2>&1 \
    || fail "platform-mismatch-$side"
done

for side in old new; do
  if [ "$side" = old ]; then f="$OLD"; else f="$NEW"; fi
  jq -e '[.Results[]? | (.Packages // []) | length] | add // 0 | . > 0' "$f" >/dev/null 2>&1 \
    || fail "no-packages-$side"
done

jq -rn --slurpfile old "$OLD" --slurpfile new "$NEW" '
  def entries:
    [ .Results[]?
      | select(.Class == "os-pkgs" or .Class == "lang-pkgs")
      | (if .Class == "os-pkgs" then "os" else "lang" end) as $c
      | (.Vulnerabilities // [])
      | if type == "array" then .[] else error("vulnerabilities not an array") end
      | if (type == "object" and (.VulnerabilityID | type) == "string"
            and (.PkgName | type) == "string")
        then . else error("malformed vulnerability entry") end
      | { c: $c, id: .VulnerabilityID, pkg: .PkgName,
          inst: (.InstalledVersion // ""), fix: (.FixedVersion // ""),
          sev: (.Severity // "") } ]
    | unique_by([.c, .id, .pkg]);
  def keyset: map({key: ([.c, .id, .pkg] | join("\t")), value: true}) | from_entries;
  def row($dir):
    [$dir, (if .fix == "" then "unfixed" else "fixable" end), .c, .id, .pkg,
     .inst, (if .fix == "" then "-" else .fix end), .sev];
  ($old[0] | entries) as $o
  | ($new[0] | entries) as $n
  | ($o | keyset) as $ok
  | ($n | keyset) as $nk
  | ( [ $n[] | select($ok[[.c, .id, .pkg] | join("\t")] | not) | row("introduced") ]
    + [ $o[] | select($nk[[.c, .id, .pkg] | join("\t")] | not) | row("fixed") ] )
  | sort[] | @tsv
' 2>/dev/null || fail invalid-json
