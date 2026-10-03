# mock-guest.tcl — a test double that stands in for qemu.
#
# Spawned through the NB_QEMU_ARGV hook in harness/spawn.exp.inc. It prints a
# production-shaped serial stream (loader -> kernel -> getty banner -> login
# -> zsh -> suite markers -> sentinel -> end-state -> poweroff) and answers
# the harness's input at each phase, so the REAL harness code runs end to end:
# the same expect scripts, the same generated arms, the same exit classes.
#
# env:
#   NB_SELFTEST        ok (default) | fail | nosummary | deadend | reboot
#   NB_SELFTEST_MARKERS  path to the plan from `gen-arms.tcl list`:
#                         one `OK|SKIP|FAIL <marker> <owner>` line each;
#                         kernel-extensions markers go to the iokit suite,
#                         the rest to the launchd-mach suite
#   NB_ARCH            arch name to print in the getty banner
#
# Mode semantics (the exit class the harness is expected to reach):
#   ok         every marker OK/SKIP per the plan, sentinel fail=0  -> rc 0
#   fail       the plan's FAIL marker emits -FAIL                   -> rc 1
#   nosummary  markers emitted, sentinel line never printed         -> rc 2
#   deadend    process exits after the first marker                 -> rc 2
#   reboot     answers shutdown -p with a reboot                    -> rc 1

set mode ok
if {[info exists env(NB_SELFTEST)] && $env(NB_SELFTEST) ne ""} { set mode $env(NB_SELFTEST) }
set arch amd64
if {[info exists env(NB_ARCH)] && $env(NB_ARCH) ne ""} { set arch $env(NB_ARCH) }

proc say {line} { puts -nonewline "$line\r\n" }
proc sayraw {s} { puts -nonewline $s }
proc prompt {} { sayraw "admin@selftest ~ % " }
proc readline {} {
    set line [gets stdin]
    if {eof stdin} { exit 0 }
    return [string trim $line]
}

# ----------------------------------------------------------------- the plan --
set plan_s1 {}
set plan_s2 {}
if {[info exists env(NB_SELFTEST_MARKERS)] && [file exists $env(NB_SELFTEST_MARKERS)]} {
    set fh [open $env(NB_SELFTEST_MARKERS) r]
    while {[gets $fh line] >= 0} {
        if {[string trim $line] eq ""} continue
        lassign [split [string trim $line]] kind marker owner
        if {$owner eq "nextbsd-kernel-extensions"} {
            lappend plan_s2 [list $kind $marker]
        } else {
            lappend plan_s1 [list $kind $marker]
        }
    }
    close $fh
}

proc emit_plan {planvar} {
    upvar 1 $planvar plan
    global mode
    set ok 0; set fail 0; set skip 0
    foreach entry $plan {
        lassign $entry kind marker
        if {$mode eq "deadend" && [expr {$ok + $fail + $skip}] >= 1} {
            exit 0
        }
        # In `ok` mode the plan's single FAIL line (the failure target) passes.
        if {$kind eq "FAIL" && $mode ne "fail"} { set kind OK }
        if {$kind eq "FAIL"} {
            say "$marker-FAIL"; incr fail
        } elseif {$kind eq "SKIP"} {
            say "$marker-SKIP"; incr skip
        } else {
            say "$marker-OK"; incr ok
        }
    }
    if {$mode eq "nosummary"} { return }
    say "NEXTBSD-TEST-SUMMARY ok=$ok fail=$fail skip=$skip"
}

# ----------------------------------------------------------------- the boot --
say "FreeBSD/amd64 EFI loader, Revision 3.0"
say "Loading /boot/loader.conf"
say "Hit [Enter] to boot immediately, or any other key for command prompt."
sayraw "OK "

while {1} {
    set line [readline]
    if {[string match "*boot -v" $line] || $line eq "boot"} { break }
    say "OK $line"
    sayraw "OK "
}

say "Booting [/boot/kernel/kernel]"
say "---<<BOOT>>---"
say "Copyright (c) 1992-2025 The FreeBSD Project."
say "early-init: sethostname('selftest')"
say "early-init: opened /dev/klog (kernel.log_open=1; console quiet)"
say "NextBSD/$arch (selftest) (console)"
after 300

# The login: path (deterministic and fast for the selftest; the automatic-
# login path takes the 8-minute wait and is covered by the production boots).
say "login:"
set line [readline]                     ;# admin
say "Password:"
set line [readline]                     ;# empty
prompt
set line [readline]                     ;# the r() wrapper definition
prompt

while {1} {
    set line [readline]
    if {$line eq "" || [string match "r()*" $line]} {
        prompt
    } elseif {[string match "*freebsd-launchd-mach*" $line]} {
        emit_plan plan_s1
        prompt
    } elseif {[string match "*iokit*" $line]} {
        emit_plan plan_s2
        prompt
    } elseif {[string match "*NB-SHELL-READY*" $line]} {
        say "NB-SHELL-READY"
        prompt
    } elseif {[string match "*NB-END-STATE*" $line]} {
        say "NB-END-STATE"
        prompt
    } elseif {[string match "*shutdown*" $line]} {
        if {$mode eq "reboot"} {
            say "Rebooting system now..."
            exit 0
        }
        say "Waiting (max 60 seconds) for system process \"login\" to stop"
        say "Syncing disks..."
        say "All buffers synced."
        say "Uptime:  0 day  0:02,  2 users,  load average: 0.00, 0.00, 0.00"
        say "Powering system off"
        after 500
        exit 0
    } else {
        say "mock-guest: unhandled input: $line"
        prompt
    }
}
