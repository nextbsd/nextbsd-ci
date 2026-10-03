#!/bin/sh
# boot-test.sh — the shared NextBSD boot-test harness entry point (nextbsd-ci).
#
# Boots <image> in qemu on a native-arch runner, applies THE loader contract
# (harness/contract.exp.inc: serial console + boot -v, every arch, one place),
# logs in, runs the on-image suite(s), and gates on the sentinel protocol:
#
#   exit 0  NEXTBSD-TEST-SUMMARY seen for every suite, no must-pass failure,
#           the end-state held, and a clean poweroff
#   exit 1  an assertion failed (a must-pass marker, the summary verdict, the
#           banner, or the teardown)
#   exit 2  a hang (never reached login, no sentinel within the suite budget,
#           or the end-state was lost after the suite) — consumers re-gate on
#           2 regardless of any boot_soft (nextbsd-userland#87/#117)
#
# usage:
#   [ARCH=amd64|arm64] [NB_SUITE="path1 path2"] [NB_SUITE_TIMEOUT=480]
#   [NB_OVERLAY=manifest/overlay-<repo>.tsv] [NB_BOOT_TRACE=0|1]
#   [NB_MEDIA=disk|cd] [NB_QEMU_ARGV=...]
#   boot-test.sh path/to/image.img[.zip|.gz]
#
# NB_SUITE is one or more on-image suites (space-separated), each of which
# must end by printing NEXTBSD-TEST-SUMMARY — that line is the contract (T2
# added it to the shipped suites; the legacy LAUNCHD-MACH-RUN-DONE /
# IOKIT-RUN-DONE done-sentinels are still fine to emit, they are simply not
# what the harness waits on).

set -eu

IMG=${1:?usage: boot-test.sh path/to/disk.img[.zip|.gz]}

if [ ! -f "$IMG" ]; then
    echo "ERROR: $IMG not found"
    exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

mkdir -p tests
LOG=tests/boot.log
EXP=tests/boot.exp
: > "$LOG"

# The as-published name (NextBSD-<arch>-<date>.img.zip) is what carries the
# arch; $IMG is rewritten to the extracted scratch copy below.
ARTIFACT=$IMG

# Accept the published image in any of: raw .img, .zip (current published
# format — single-entry archive containing the NextBSD-<arch>.img raw image),
# .gz (legacy). Extract/decompress to a raw .img that qemu can boot as a disk.
case "$IMG" in
*.zip)
    RAW=tests/disk.img
    echo "==> extracting $IMG -> $RAW"
    MEMBER=$(unzip -Z1 "$IMG" | grep -E '\.img$' | head -1)
    [ -n "$MEMBER" ] || { echo "FAIL: no .img member in $IMG" >&2; exit 1; }
    unzip -p "$IMG" "$MEMBER" > "$RAW"
    IMG=$RAW
    ;;
*.gz)
    RAW=tests/disk.img
    echo "==> decompressing $IMG -> $RAW"
    gunzip -c "$IMG" > "$RAW"
    IMG=$RAW
    ;;
esac

echo "==> boot test: $IMG"
ls -lh "$IMG"

# $HERE is runtime-resolved, so shellcheck's -x cannot follow it from the
# repo root; qemu-arch.sh is linted as its own file by the same find.
# shellcheck disable=SC1091
. "$HERE/qemu-arch.sh"
qemu_arch_setup "$IMG" "$ARTIFACT"

NB_SUITE=${NB_SUITE:-/usr/tests/freebsd-launchd-mach/run.sh}
NB_SUITE_TIMEOUT=${NB_SUITE_TIMEOUT:-480}
NB_OVERLAY=${NB_OVERLAY:-$ROOT/manifest/overlay-nextbsd.tsv}
NB_BOOT_TRACE=${NB_BOOT_TRACE:-0}
NB_MEDIA=${NB_MEDIA:-disk}
NB_DEBUG=${NB_DEBUG:-}
# NB_LOGIN_ONLY=1: boot -> login -> clean end-state -> poweroff, and NO on-image
# suite. For images that ship no sentinel-emitting suite (the kernel smoke image,
# the nextbsd img/iso light-smoke gates): those boots gate on "reached login and
# stayed up", not on a userland marker suite the image doesn't carry.
NB_LOGIN_ONLY=${NB_LOGIN_ONLY:-}
if [ -n "$NB_LOGIN_ONLY" ]; then
    NB_SUITE=""
    echo "==> login-only mode: no on-image suite (gate on login + clean end-state)"
fi

# The banner verdict policy: the consumer's overlay wins, then the base table,
# then warn (the nextbsd monolith's long-standing treatment).
NB_BANNER_POLICY=""
for t in "$NB_OVERLAY" "$ROOT/manifest/markers.tsv"; do
    [ -f "$t" ] || continue
    NB_BANNER_POLICY=$(awk -F'\t' -v m=BOOT-BANNER '$1 == m {print $4; exit}' "$t")
    [ -n "$NB_BANNER_POLICY" ] && break
done
[ -n "$NB_BANNER_POLICY" ] || NB_BANNER_POLICY=warn

# NB_TIMEOUT_GLOBAL: the global expect budget in seconds (default 480 = the 8
# minutes a TCG arm64 boot needs). The selftest sets it small so a broken arm
# fails in seconds. NB_SUITE_TIMEOUT: per-suite budget for the sentinel blocks.
NB_TIMEOUT_GLOBAL=${NB_TIMEOUT_GLOBAL:-480}
export NB_LOG="$LOG" NB_MEDIA NB_BOOT_TRACE NB_BANNER_POLICY NB_QEMU_ARGV="${NB_QEMU_ARGV:-}" NB_TIMEOUT_GLOBAL NB_SUITE_TIMEOUT NB_DEBUG

# manifest -> expect arms (one block per suite, generated for this arch and
# overlay; selftest passes NB_QEMU_ARGV so no firmware is needed)
NSUITE=$(printf '%s' "$NB_SUITE" | wc -w | tr -d ' ')
if ! tclsh "$ROOT/manifest/gen-arms.tcl" "$ROOT/manifest/markers.tsv" "$NB_OVERLAY" "$ARCH" "$NSUITE" "$NB_SUITE" > "$EXP.arms"; then
    echo "FAIL: arm generation failed (bad manifest?); refusing to boot without arms"
    exit 1
fi

{
    cat "$HERE/patterns.tcl"
    cat "$HERE/spawn.exp.inc"
    cat "$HERE/loader.exp.inc"
    cat "$HERE/contract.exp.inc"
    cat "$HERE/login.exp.inc"
    cat "$EXP.arms"
    cat "$HERE/suite-tail.exp.inc"
    cat "$HERE/teardown.exp.inc"
} > "$EXP"

if [ -n "$NB_DEBUG" ]; then
    echo "=== DBG: $EXP total lines: $(wc -l < "$EXP")"
    grep -n 'set nb_scope\|set nb_pol(ACCT-HELPERS)\|running on-image suite\|set nb_mustpass' "$EXP" | head
    echo "=== DBG: context around the suite expect"
    sed -n '355,380p' "$EXP"
    echo "=== DBG: context around the marker arm"
    sed -n '655,690p' "$EXP"
fi

set +e
expect -f "$EXP" "$IMG"
rc=$?
set -e

# Informational: the suite's own aggregate verdict, straight from the transcript.
# The expect rc above is the gate; this is for the workflow logs. Skipped in
# login-only mode (no suite ran, so there is no sentinel aggregate to show).
if [ -z "$NB_LOGIN_ONLY" ]; then
    sh "$HERE/summary.sh" "$LOG" || true
fi

if [ "$rc" -eq 0 ]; then
    echo "==> boot-test PASSED (arch=$ARCH suite=$NB_SUITE)"
else
    echo "==> boot-test FAILED rc=$rc (arch=$ARCH suite=$NB_SUITE)"
    echo "    serial transcript: $LOG"
fi
exit "$rc"
