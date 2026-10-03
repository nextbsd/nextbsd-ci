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
    -re {panic|Fatal trap|Fatal data abort} {
        puts "\nFAIL: kernel panic in the end-state window"
        exit 1
    }
    "NB-END-STATE" { puts "\nOK: shell alive after the suite" }
    -re {[#%$] $} { puts "\nOK: shell alive after the suite" }
}
