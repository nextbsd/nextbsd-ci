# manifest/

The machine-readable record of which markers run where, and what each one
gates. The harness generates its expect arms *from* these tables — no
per-marker judgment lives in the expect scripts (that was the divergence:
five copies, five answers to the same gate questions).

## Files

| file | role |
|---|---|
| `markers.tsv` | the base table: every marker any NextBSD boot image can emit |
| `overlay-nextbsd.tsv` | tolerances for the `nextbsd` repo's boot tests |
| `overlay-nextbsd-userland.tsv` | tolerances for the `nextbsd-userland` workflows |
| `overlay-nextbsd-kernel.tsv` | tolerances for the `nextbsd-kernel` smoke tests |
| `gen-arms.tcl` | table → expect arms (one sentinel block per suite) |
| `validate.sh` | schema check, run by CI |

## Schema (6 tab-separated columns)

```
marker	owner	arches	policy	timeout	reason
```

- **marker** — the name the on-image suite prints, e.g. `MACH-SMOKE`. Suites
  print `MARKER-OK` / `MARKER-FAIL` / `MARKER-SKIP` (line-anchored).
- **owner** — the repo that emits it (`nextbsd`, `nextbsd-userland`,
  `nextbsd-kernel`, `nextbsd-kernel-extensions`, `nextbsd-freebsd-compat`,
  `nextbsd-overlays`). A fix that changes a marker lands with its owner.
- **arches** — `both`, `amd64`, or `arm64`: the arch(es) on which the marker
  is *expected*. On the other arch, the arm still runs but only logs
  (a `KEXTD-LOAD-SKIP` on arm64 is data, not a surprise).
- **policy** — the gate decision (see below).
- **timeout** — the class of failure the marker's arm must catch
  (`ok`, `fail`, `hang`, or `timeout`): it documents which of the sentinel
  protocol's exit classes the marker can trip.
- **reason** — the decision, in words. This is the audit trail for T3: every
  must-pass must say *why the capability ships in the image*.

`overlay-*.tsv` use the same schema; a row overrides the base table's row of
the same marker, for that consumer only. `validate.sh` checks the schema and
lists the cross-file overrides.

## Policy → expect arm

`gen-arms.tcl` turns a marker into expect arms per policy:

| policy | `-FAIL` | `-OK` | `-SKIP` | absent |
|---|---|---|---|---|
| `must-pass` | `exit 1` | record | `exit 1` (a must-pass that self-skipped is an absent capability) | `exit 1` (the absence check, suite-tail) |
| `fail-gates` | `exit 1` | record | record (WARN) | not checked |
| `warn` | record (WARN) | record | record (WARN) | not checked |

The `-OK`/`-FAIL`/`-SKIP` arms of every marker sit in the same expect block
as the suite's sentinel arm, so a marker can never scroll past an earlier
wait (the #405 interleaving class).

## Sentinel protocol (T1)

Each on-image suite ends by printing one aggregate line and exiting with its
fail count:

```
NEXTBSD-TEST-SUMMARY ok=<n> fail=<n> skip=<n>
```

The harness arm on that line: `fail` > the number of manifest-`warn` failures
in the suite ⇒ `exit 1`. No sentinel within `NB_SUITE_TIMEOUT` ⇒ `exit 2`
(the hang class). Exit codes: `0` pass · `1` a must-pass/verdict failure ·
`2` a hang (consumers re-gate on 2 regardless of `boot_soft` —
nextbsd-userland#117).

## Exit-code contract

| rc | meaning |
|---|---|
| 0 | every suite sentinelled, no must-pass failure, end-state held, clean poweroff |
| 1 | an assertion failed (a must-pass marker, the summary verdict, the banner, or the teardown) |
| 2 | a hang (never reached login, no sentinel, or the end-state was lost after the suite) |
