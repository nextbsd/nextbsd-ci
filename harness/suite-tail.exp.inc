# suite-tail.exp.inc — what runs after the per-suite sentinel blocks close:
# the must-pass absence check, the recorded banner verdict, and the final
# end-state confirmation, before any PASS can be printed.
#
# The absence check is the "a must-pass marker that didn't emit fails the
# lane" half of the protocol: the summary arm proved the suite completed
# (and that its own aggregate verdict was green), so a must-pass marker that
# never appeared was never run — an image that predates the capability, or a
# suite that quietly skipped it. Consumers that boot older continuous images
# declare the tolerance in their overlay (warn), which removes the marker
# from this check.

# The absence check applies only when a suite actually ran. A login-only boot
# (NB_LOGIN_ONLY, no on-image suite) has no markers to require, so a must-pass
# marker that never appeared is expected there, not a failure.
if {[info exists nb_suites_ran] && $nb_suites_ran > 0} {
    set nb_missing 0
    foreach m $nb_mustpass {
        if {![info exists nb_seen($m)]} {
            if {$nb_scope eq "any" || [expr {[llength $nb_scope] > 0 && [lsearch -exact $nb_scope [set nb_owner($m)]] >= 0}]} {
                puts "\nFAIL: $m — must-pass marker never emitted (suite did not reach it, or the image predates the capability; overlay to warn if that is expected)"
                incr nb_missing
            } else {
                puts "\nINFO: $m — must-pass but owned by [set nb_owner($m)]; no running suite owns it, so it is out of scope for this boot"
            }
        }
    }
    if {$nb_missing > 0} {
        puts "\nFAIL: $nb_missing must-pass marker(s) missing from the suite output"
        exit 1
    }
} else {
    puts "\nOK: login-only boot (no on-image suite) — skipping the must-pass absence check"
}

if {[info exists banner_fail] && $banner_fail ne ""} {
    if {$env(NB_BANNER_POLICY) eq "must-pass"} {
        puts "\nFAIL: BOOT-BANNER — $banner_fail"
        exit 1
    }
    puts "\nWARN: BOOT-BANNER — $banner_fail (informational per manifest)"
}

# Final end-state (nextbsd#428): a PASS at the login prompt is not a PASS if
# the system resets seconds later. After the suite, before any PASS, the shell
# must still answer. A lost end-state is the hang class: exit 2.
if {[info exists env(NB_TIMEOUT_GLOBAL)] && $env(NB_TIMEOUT_GLOBAL) ne ""} {
    set timeout [expr {$env(NB_TIMEOUT_GLOBAL) + 0}]
} else {
    set timeout 60
}
send "\r"
send "echo NB-END-STATE\r"
expect {
    timeout {
        puts "\nFAIL: shell did not answer after the suite — end-state lost (the nextbsd#428 class); no PASS"
        exit 2
    }
    -re $re_panic {
        puts "\nFAIL: kernel panic in the end-state window"
        exit 1
    }
    "NB-END-STATE" { puts "\nOK: shell alive after the suite" }
    -re {[#%$] $} { puts "\nOK: shell alive after the suite" }
}

# #428 end-state HOLD: a single probe is not a stability proof. The class this
# ticket names is a system that answers the probe fine, then resets seconds
# later -- after the harness has already committed to a PASS and is tearing
# down. So hold the console for a bounded window: heartbeat the shell (proof
# it is still the same live session), then watch for the reset signals (a
# fresh getty banner, a reboot line, a panic, or the console dying). Any of
# them means the end-state was not real -> the hang class, exit 2 (a panic is
# exit 1). The window is capped by the remaining global budget so it can never
# push a boot past its own timeout.
set _saved_hold_timeout $timeout
set _hold 15
if {$timeout < $_hold} { set _hold $timeout }
set _hb 0
set timeout [expr {$_hold / 2}]
send "echo NB-HOLD\r"
expect {
    timeout { set _hb 0 }
    -re $re_reboot      { puts "\nFAIL: system rebooted during the end-state hold (nextbsd#428)"; exit 2 }
    -re $re_panic       { puts "\nFAIL: kernel panic during the end-state hold (nextbsd#428)"; exit 1 }
    -re $re_boot_banner { puts "\nFAIL: a fresh getty banner during the end-state hold — the system reset (nextbsd#428)"; exit 2 }
    eof                 { puts "\nFAIL: the console died during the end-state hold (nextbsd#428)"; exit 2 }
    "NB-HOLD"           { set _hb 1 }
}
set timeout [expr {$_hold / 2}]
if {$_hb} {
    expect {
        timeout { puts "\nOK: end-state held for ${_hold}s — shell alive, no reset (nextbsd#428)" }
        -re $re_reboot      { puts "\nFAIL: system rebooted after the end-state heartbeat (nextbsd#428)"; exit 2 }
        -re $re_panic       { puts "\nFAIL: kernel panic after the end-state heartbeat (nextbsd#428)"; exit 1 }
        -re $re_boot_banner { puts "\nFAIL: a fresh getty banner after the end-state heartbeat — the system reset (nextbsd#428)"; exit 2 }
        eof                 { puts "\nFAIL: the console died after the end-state heartbeat (nextbsd#428)"; exit 2 }
    }
} else {
    puts "\nWARN: no end-state heartbeat (the probe above passed; shell may be wedged) — proceeding to teardown"
}
set timeout $_saved_hold_timeout
