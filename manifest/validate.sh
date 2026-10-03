#!/bin/sh
# validate.sh — static schema check for the marker manifest tables.
#
# usage: validate.sh [file ...]     (default: the base table next to this script)
#
# Checks, per file:
#   - a `marker owner arches policy timeout reason` header row
#   - exactly 6 tab-separated columns
#   - marker:  [A-Za-z0-9][A-Za-z0-9-]*   (it is the expect-arm name)
#   - owner:   [a-z][a-z0-9-]*            (the repo that emits it)
#   - arches:  both | amd64 | arm64
#   - policy:  must-pass | fail-gates | warn
#   - timeout: integer seconds
#   - no duplicate markers within the same file
#
# When more than one file is passed, a marker appearing in several files is a
# declared overlay (the last file wins) and is noted, not failed. Exit 1 on
# any violation; the violations are all listed.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -gt 0 ] || set -- "$HERE/markers.tsv"

status=0
for f in "$@"; do
    [ -f "$f" ] || { echo "ERROR: $f not found"; status=1; continue; }
    awk -F'\t' -v fname="$f" '
        function bad(msg) { print fname ": line " NR ": " msg; fbad = 1 }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        $1 == "marker" {
            if ($0 != "marker\towner\tarches\tpolicy\ttimeout\treason")
                bad("header must be: marker\\towner\\tarches\\tpolicy\\ttimeout\\treason")
            header = 1
            next
        }
        {
            if (!header) bad("rows before the header row")
            if (NF != 6) { bad("expected 6 columns, got " NF); next }
            if ($1 !~ /^[A-Za-z0-9][A-Za-z0-9-]*$/) bad("bad marker name: " $1)
            if ($2 !~ /^[a-z][a-z0-9-]*$/)        bad("bad owner: " $2)
            if ($3 != "both" && $3 != "amd64" && $3 != "arm64") bad("bad arches: " $3)
            if ($4 != "must-pass" && $4 != "fail-gates" && $4 != "warn") bad("bad policy: " $4)
            if ($5 !~ /^[0-9]+$/)                 bad("timeout must be integer seconds: " $5)
            if ($1 in seen) bad("duplicate marker: " $1)
            seen[$1] = 1
            rows++
        }
        END {
            if (!header) bad("no header row")
            if (fbad) exit 1
            print fname ": " rows " markers OK"
        }
    ' "$f" || status=1
done

# Cross-file: note overrides (legal — the later file wins in gen-arms).
if [ $# -gt 1 ]; then
    for m in $(awk -F'\t' 'NR > 1 && $1 != "marker" && $1 !~ /^#/ && $1 != "" {print $1}' "$@" | sort | uniq -d); do
        echo "NOTE: $m is declared in multiple files (later file overrides)"
    done
fi

exit "$status"
