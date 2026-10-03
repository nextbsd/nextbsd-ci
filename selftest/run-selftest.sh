#!/bin/sh
# run-selftest.sh — exercise the real harness against the mock guest.
#
# The mock stands in for qemu (NB_QEMU_ARGV), so this runs the same expect
# scripts the production boots run, end to end, in a few seconds: arm
# generation, the sentinel protocol, the exit classes, the banner, the
# end-state, and the teardown.
#
# Every case is a full harness run; a case passes only when the harness exits
# with exactly the class its mock scenario describes. Exit 0 iff all pass.
#
#   [ARCH=amd64|arm64] run-selftest.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
cd "$ROOT"
ARCH=${ARCH:-amd64}

command -v tclsh >/dev/null 2>&1 || { echo "SELFTEST ERROR: tclsh not found (install the expect package)"; exit 1; }
command -v expect >/dev/null 2>&1 || { echo "SELFTEST ERROR: expect not found (install the expect package)"; exit 1; }

fail=0

echo "==> golden: the shared patterns against production stream shapes"
if expect -f "$HERE/regex-golden.exp"; then :; else fail=1; fi

echo "==> manifest: schema"
if sh "$ROOT/manifest/validate.sh" "$ROOT/manifest/markers.tsv" \
   "$ROOT/manifest/overlay-nextbsd.tsv" \
   "$ROOT/manifest/overlay-nextbsd-userland.tsv" \
   "$ROOT/manifest/overlay-nextbsd-kernel.tsv"; then :; else fail=1; fi

echo "==> harness vs mock guest (arch=$ARCH)"
mkdir -p tests
touch tests/fake.img   # the mock guest never reads the image

# The marker plan: one line per marker (kind, marker, owner) for the mock.
tclsh "$ROOT/manifest/gen-arms.tcl" list "$ROOT/manifest/markers.tsv" /dev/null "$ARCH" > tests/plan.tsv
[ -s tests/plan.tsv ] || { echo "SELFTEST FAIL: no marker plan generated"; exit 1; }
echo "    plan: $(wc -l < tests/plan.tsv) markers"

export ARCH
export NB_QEMU_ARGV="tclsh $HERE/mock-guest.tcl"
export NB_TIMEOUT_GLOBAL=30
export NB_SUITE_TIMEOUT=20
export NB_MEDIA=disk
export NB_OVERLAY=/dev/null
export NB_DEBUG=1

run_case() {
    name=$1
    expect_rc=$2
    suite=$3
    login_only=${4:-}
    echo "==> case: $name (suite: $suite, login_only: ${login_only:-no}) — expect rc $expect_rc"
    set +e
    NB_SELFTEST=$name NB_SELFTEST_MARKERS="$HERE/../tests/plan.tsv" \
        NB_SUITE="$suite" NB_LOGIN_ONLY="$login_only" sh "$ROOT/harness/boot-test.sh" tests/fake.img
    rc=$?
    set -e
    if [ "$rc" -ne "$expect_rc" ]; then
        echo "SELFTEST FAIL: case $name — expected rc $expect_rc, got $rc"
        fail=1
    else
        echo "SELFTEST OK:   case $name (rc=$rc)"
    fi
}

run_case ok        0 /usr/tests/freebsd-launchd-mach/run.sh
run_case fail      1 /usr/tests/freebsd-launchd-mach/run.sh
run_case nosummary 2 /usr/tests/freebsd-launchd-mach/run.sh
run_case deadend   2 /usr/tests/freebsd-launchd-mach/run.sh
run_case reboot    1 /usr/tests/freebsd-launchd-mach/run.sh
run_case two-suite 0 "/usr/tests/freebsd-launchd-mach/run.sh /usr/tests/nextbsd-iokit/run.sh"
# login-only: no on-image suite (an image that ships no sentinel suite, e.g. the
# kernel smoke image or nextbsd img/iso). Reaches login, skips the absence check,
# holds a clean end-state, powers off -> rc 0.
run_case loginonly 0 "" 1

if [ "$fail" -ne 0 ]; then
    echo "==> SELFTEST FAILED"
    exit 1
fi
echo "==> SELFTEST PASSED (all cases)"
