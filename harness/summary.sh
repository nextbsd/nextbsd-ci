#!/bin/sh
# summary.sh — parse the NEXTBSD-TEST-SUMMARY line out of a serial transcript.
#
# The on-image suites print one aggregate line as their last marker output:
#   NEXTBSD-TEST-SUMMARY ok=<n> fail=<n> skip=<n>
# Consumers whose workflows want to re-gate on the suite's own verdict (the
# way nextbsd-userland's build-arch.yml re-gates on the boot rc) can call this
# on the uploaded boot log instead of re-parsing markers.
#
# Exit: 0  summary present and fail=0
#         1  summary present with fail>0
#         2  no summary in the log (the suite never completed — the hang class)
LOG=${1:?usage: summary.sh serial-log}
[ -f "$LOG" ] || { echo "ERROR: $LOG not found" >&2; exit 2; }

line=$(grep -a 'NEXTBSD-TEST-SUMMARY' "$LOG" | tail -1)
if [ -z "$line" ]; then
    echo "no NEXTBSD-TEST-SUMMARY in $LOG"
    exit 2
fi

ok=$(printf '%s\n' "$line" | sed -nE 's/.* ok=([0-9]+).*/\1/p')
fail=$(printf '%s\n' "$line" | sed -nE 's/.* fail=([0-9]+).*/\1/p')
skip=$(printf '%s\n' "$line" | sed -nE 's/.* skip=([0-9]+).*/\1/p')
echo "NEXTBSD-TEST-SUMMARY ok=$ok fail=$fail skip=$skip"

if [ "$fail" = "0" ]; then
    exit 0
fi
exit 1
