#!/usr/bin/env bash
# image-compare-intake.sh — validate the untrusted image-compare handoff.
#
# Usage: image-compare-intake.sh <expected-images-file>  < decoded-handoff
#   expected-images-file  one <name>\t<version> per line (the images the scan
#                         job extracted itself)
#   stdin                 decoded handoff: `pair` (7 columns) and `vuln`
#                         (13 columns) TSV rows produced by the unprivileged
#                         image-compare job. Treated as untrusted data.
#
# Pure logic: awk only; no network.
# Fail-closed: any malformed line, or a pair/vuln whose new image is not
# expected, prints NOTHING on stdout and exits 2.
#
# Output (stdout):
#   image\t<name>\t<version>\t<status>   one per expected image; status is `ok`,
#                                        `missing-comparison` (no pair), or the
#                                        first non-ok pair status for that image
#   followed by the validated pair/vuln rows, unchanged.

set -u

[ "$#" -eq 1 ] && [ -f "$1" ] || { echo "usage: image-compare-intake.sh <expected-images-file>" >&2; exit 2; }

awk -F '\t' '
  function nv(s) { return s ~ /^[A-Za-z0-9][A-Za-z0-9._\/:@-]*$/ }
  function idok(s) { return s ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/ }
  function pkgok(s) { return s ~ /^[A-Za-z0-9@][A-Za-z0-9._+:\/@~-]*$/ }
  function verok(s) { return s == "-" || s ~ /^[A-Za-z0-9][A-Za-z0-9._+:~, -]*$/ }
  function bad() { failed = 1; exit 2 }
  FILENAME == ARGV[1] {
    if ($0 == "") next
    n++; en[n] = $1; ev[n] = $2; known[$1 "\t" $2] = 1; st[$1 "\t" $2] = ""
    next
  }
  $0 == "" { next }
  $1 == "pair" {
    if (NF != 7) bad()
    if (!nv($2) || !nv($3)) bad()
    if (!(($2 "\t" $3) in known)) bad()
    if ($7 !~ /^[a-z0-9-]+$/ || $6 != "linux/amd64") bad()
    k = $2 "\t" $3
    if ($7 == "ok") { if (!nv($4) || !nv($5)) bad() }
    else {
      if (!(nv($4) || $4 == "-") || !(nv($5) || $5 == "-")) bad()
      if (st[k] == "") st[k] = $7
    }
    seen[k] = 1
    rows[++r] = $0
    next
  }
  $1 == "vuln" {
    if (NF != 13) bad()
    if (!nv($2) || !nv($3) || !nv($4) || !nv($5)) bad()
    if (!(($2 "\t" $3) in known)) bad()
    if ($6 != "introduced" && $6 != "fixed") bad()
    if ($7 != "fixable" && $7 != "unfixed") bad()
    if ($8 != "os" && $8 != "lang") bad()
    if (!idok($9) || !pkgok($10) || !verok($11) || !verok($12)) bad()
    if ($13 !~ /^(UNKNOWN|LOW|MEDIUM|HIGH|CRITICAL)$/) bad()
    rows[++r] = $0
    next
  }
  { bad() }
  END {
    if (failed) exit 2
    for (i = 1; i <= n; i++) {
      k = en[i] "\t" ev[i]
      s = (k in seen) ? (st[k] == "" ? "ok" : st[k]) : "missing-comparison"
      printf "image\t%s\t%s\t%s\n", en[i], ev[i], s
    }
    for (i = 1; i <= r; i++) print rows[i]
  }
' "$1" -
