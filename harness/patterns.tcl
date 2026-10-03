# patterns.tcl — the serial-stream regexes, in one place.
#
# Sourced first by every harness .exp.inc file, and independently by
# selftest/regex-golden.exp, so the golden test asserts on exactly the
# patterns the harness matches. If a pattern must change, it changes here,
# once, and the golden test re-proves it against production stream samples.
#
# Provenance: the loader/banner/login/teardown patterns are the strings the
# five diverged copies carried (nextbsd/tests/loader.exp.inc,
# nextbsd-userland/tests/boot-test.sh). Every pattern is brace-quoted with
# explicit character classes, so it compiles the same under any Tcl
# double-quote backslash behavior: the production runners match the
# double-quoted forms, and the selftest (same runners) re-proves the
# brace forms against the same stream shapes.
#
# re_summary is new (the T1 sentinel contract).

# The loader's autoboot countdown line (EDK2) and its UEFI self-identification.
# Brand-agnostic: the kernel rebranded ostype to NextBSD; the UEFI loader may
# still say FreeBSD. Matched, neither a rebrand nor a rename breaks the handshake.
set re_hit_enter  {Hit \[Enter\]}
set re_efi_banner {[A-Za-z]*BSD/[A-Za-z0-9._-]+ EFI}

# getty's boot banner: "<ostype>/<machine> (HOSTNAME) (console)". The
# hostname is captured for the BOOT-BANNER marker (the early-init race,
# nextbsd#325).
set re_boot_banner {[A-Za-z]*BSD/[A-Za-z0-9_]+ \(([A-Za-z0-9._-]+)\) \(console\)}
set re_early_init  {early-init: sethostname\('([^']+)'\)}

# login(1)'s session message (a syslog line that only reaches the console when
# syslogd is unreachable — nextbsd-userland#289) and the shell prompt.
set re_session_msg  {login on console as ([a-z_][a-z0-9_.-]*)}
set re_shell_prompt {[#%$] $}

# The panic family, and the loader's "we are leaving the prompt" signals.
set re_panic   {panic|Fatal trap|Fatal data abort}
set re_boot_go {Booting|/boot/kernel/kernel|Loading kernel|---<<}

# Teardown: shutdown(8) progress markers, the poweroff line, the reboot line.
set re_shutdown_wait {Waiting \(max [0-9]+ seconds\)|Syncing disks|All buffers synced|Uptime:}
set re_poweroff      {Powering system off}
set re_reboot        {Rebooting|rebooting}

# The sentinel (T1): one aggregate line per on-image suite.
set re_summary {NEXTBSD-TEST-SUMMARY ok=([0-9]+) fail=([0-9]+) skip=([0-9]+)}

# A capability marker line (T1): "<NAME>-<OK|SKIP|FAIL>".
# Matched by ONE arm (a runtime policy table decides the outcome) instead of
# one arm per marker: the runners' expect takes the first arm in file order
# that matches ANYWHERE in the buffer, so 93 sorted marker arms let a marker
# whose text arrives late in the stream match first and consume every marker
# in between. One pattern consumes the stream strictly in arrival order.
# The line-end tail is deliberately NOT in the pattern: the selftest's
# transcript (the same bytes expect reads) shows the pty delivers the markers
# with a bare LF, and a (\r\n|\n) tail must stay out of the arm's pattern
# so a match can never fail on line-ending shape.
set re_marker {[A-Z0-9][A-Z0-9-]*-(OK|SKIP|FAIL)}
