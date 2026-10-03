# nextbsd-ci

The shared test harness for NextBSD boot tests. One home for the qemu/expect
machinery, the loader contract, the sentinel protocol, and the manifest — so
the five diverged copies of the boot test become one (nextbsd/nextbsd#443,
tickets T1–T3; assessment: [Test-Infrastructure-Assessment](https://github.com/nextbsd/nextbsd-ci/wiki/Test-Infrastructure-Assessment)).

```
harness/
  boot-test.sh        the entry point: boot <image>, run the suite(s), gate
  qemu-arch.sh        the per-arch qemu shape (sourced; amd64 q35 / arm64 virt)
  patterns.tcl        the serial-stream regexes, in one place
  spawn.exp.inc       the expect skeleton (spawn/log; NB_QEMU_ARGV override hook)
  loader.exp.inc      the FreeBSD loader serial handshake
  contract.exp.inc    THE loader contract: serial console + boot -v, every arch
  login.exp.inc       banner capture + get-to-a-shell (login: or automatic)
  suite-tail.exp.inc  must-pass absence check, banner verdict, end-state (#428)
  teardown.exp.inc    poweroff through launchd, verified (#398)
  summary.sh          parse NEXTBSD-TEST-SUMMARY out of a transcript
manifest/
  markers.tsv         marker, owner, arches, policy, timeout, reason
  overlay-*.tsv       per-consumer tolerance tables (override the base table)
  gen-arms.tcl        table -> expect arms (one sentinel block per suite)
  validate.sh         schema check (run by CI)
selftest/
  run-selftest.sh     the real harness against the mock guest (all exit classes)
  mock-guest.tcl      a fake guest: the production stream shape, in a few seconds
  regex-golden.exp    the patterns asserted against real production stream samples
```

## The protocol

The harness boots a real NextBSD image in qemu on a native-arch runner,
applies the loader contract (serial console + `boot -v`, set at the loader —
never baked into images), gets a shell, runs the on-image suite(s), and gates
on exit codes:

| rc | meaning |
|---|---|
| 0 | every suite printed its sentinel with no must-pass failure, the end-state held, clean poweroff |
| 1 | an assertion failed (a must-pass marker, the summary verdict, the banner, or the teardown) |
| 2 | a hang (never reached login, no sentinel, or the end-state was lost) — consumers re-gate on 2 regardless of `boot_soft` |

Each on-image suite ends by printing `NEXTBSD-TEST-SUMMARY ok=<n> fail=<n>
skip=<n>` (T2 adds this to the shipped suites). The manifest decides, per
marker, whether a failure gates (`must-pass`/`fail-gates`) or only logs
(`warn`); arch asymmetry is declared data, not accidental divergence.
See [manifest/README.md](manifest/README.md).

## Usage

```sh
git clone https://github.com/nextbsd/nextbsd-ci
# in your consumer workflow, on the native-arch runner (expect + tcl installed):
ARCH=amd64 NB_SUITE="/usr/tests/freebsd-launchd-mach/run.sh" \
  nextbsd-ci/harness/boot-test.sh path/to/NextBSD-amd64-<date>.img.zip
```

`NB_OVERLAY` selects the per-repo tolerance table (defaults to
`overlay-nextbsd.tsv`); `NB_BOOT_TRACE=1` opts into the launchd/mach debug
kenvs for a root-cause run; `NB_MEDIA=cd` boots a live ISO.

## Selftest

`selftest/run-selftest.sh` runs the real harness against a mock guest
(`NB_QEMU_ARGV` stands in for qemu) on each exit class — the same expect
scripts, the same generated arms — in a few seconds. This is what CI runs.

## Status (wave 1)

- **T1** (this repo): the shared harness, the sentinel contract, the manifest
  baseline, the selftest.
- **T2** (nextbsd-userland): the on-image suites emit the sentinel + exit
  code; the workflow pins this repo by tag.
- **T3** (this repo): the exit-code audit — every marker classified
  must-pass / fail-gates / warn, reasons recorded in the manifest.

Licensed BSD-2-Clause, see [LICENSE](LICENSE).
