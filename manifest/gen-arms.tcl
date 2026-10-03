# gen-arms.tcl — generate the harness's expect arms from the marker manifest.
#
# usage:
#   tclsh gen-arms.tcl <markers.tsv> <overlay.tsv> <arch> <nsuites> <suite1 [suite2 ...]>
#       emits the per-suite sentinel blocks (spliced between login.exp.inc and
#       suite-tail.exp.inc by harness/boot-test.sh)
#   tclsh gen-arms.tcl list <markers.tsv> <overlay.tsv> <arch>
#       emits one line per marker, for the selftest mock:
#         OK   <marker> <owner>   the mock should emit <marker>-OK
#         SKIP <marker> <owner>   the mock should emit <marker>-SKIP
#         FAIL <marker> <owner>   the failure target (first must-pass, else first warn)
#
# The manifest is the record of the gate decisions (T3); the harness makes no
# per-marker judgment of its own. Overlay rows override base rows (a consumer
# that boots older continuous images declares its tolerances there).
#
# Exit-code contract of the generated code:
#   0  every suite printed NEXTBSD-TEST-SUMMARY with no must-pass failure,
#      every must-pass marker was seen, and the tail (banner/end-state/
#      teardown, in suite-tail.exp.inc / teardown.exp.inc) passed
#   1  a must-pass -FAIL arm, a -FAIL that a must-pass check self-skipped,
#      the summary verdict, the absence check, the banner, or the teardown
#   2  no sentinel within NB_SUITE_TIMEOUT (suite hung or died), which is
#      what suite-tail/login use for their own hang classes

if {[lindex $argv 0] eq "list"} {
    # list mode: tclsh gen-arms.tcl list <markers.tsv> <overlay.tsv> <arch>
    set mode    list
    set base    [lindex $argv 1]
    set overlay [lindex $argv 2]
    set arch    [lindex $argv 3]
    set suites  0
} else {
    # arm mode: tclsh gen-arms.tcl <markers.tsv> <overlay.tsv> <arch> <nsuites> <suite-list>
    # The suite list is one space-separated argument (as boot-test.sh passes it).
    set mode       arms
# The shared patterns (the sentinel arm is emitted as a variable reference so
# the generator never holds a bracketed literal in a double-quoted string).
source [file normalize [file join [file dirname [info script]] .. harness patterns.tcl]]

set base    [lindex $argv 0]
    set overlay    [lindex $argv 1]
    set arch       [lindex $argv 2]
    set suites     [lindex $argv 3]
    if {![string is integer -strict $suites]} { set suites 1 }
    if {[llength $argv] > 4} {
        set suite_list [lindex $argv 4]
    } else {
        set suite_list ""
    }
}

# ------------------------------------------------------------------ loading --
# 8.6-compatible: no `array names -pattern` (an 8.7 feature) — track the
# marker list explicitly while loading.
array set eff {}
set markers {}
proc load_table {file} {
    global eff markers
    if {![file exists $file]} { return }
    set fh [open $file r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        set f [split $line "\t"]
        if {[llength $f] < 6} continue
        lassign $f m o a p t r
        if {$m eq "marker"} continue
        if {![info exists eff($m,policy)]} { lappend markers $m }
        set eff($m,owner) $o
        set eff($m,arches) $a
        set eff($m,policy) $p
        set eff($m,timeout) $t
        set eff($m,reason) $r
    }
    close $fh
}
load_table $base
load_table $overlay

# ------------------------------------------------------------ classification --
set markers [lsort -unique $markers]
set onarch {}
set offarch {}
set mustpass {}
set warnfail {}
foreach m $markers {
    set a [set eff($m,arches)]
    if {$a eq "both" || $a eq $arch} { lappend onarch $m } else { lappend offarch $m }
}
foreach m $onarch {
    set p [set eff($m,policy)]
    if {$p eq "must-pass"} { lappend mustpass $m }
    if {$p eq "warn"} { lappend warnfail $m }
}

# The reason strings go into generated Tcl double-quoted strings: escape the
# backslash first, then the quote, so the generated file parses.
proc esc {s} {
    set bs [string range {\\} 0 0]
    set s [string map [list $bs $bs$bs] $s]
    set s [string map [list {$} $bs{$}] $s]
    set q "\""
    set s [string map [list $q $bs$q] $s]
    return $s
}

# ------------------------------------------------------------------ list mode --
if {$mode eq "list"} {
    # Pick the failure target FIRST (the first must-pass, else the first
    # warn, in sort order). It is emitted only as its FAIL line: the `ok`
    # case converts that line to OK in the mock, the `fail` case emits it
    # as a real failure. Emitting an OK line AND a FAIL line for the same
    # marker would make the mock print it twice; the duplicate -OK text
    # later in the stream lets the marker arm re-match and swallow the
    # markers in between (expect resumes after the later match).
    set failtarget ""
    foreach m $mustpass {
        if {$failtarget eq ""} { set failtarget $m }
    }
    if {$failtarget eq ""} {
        foreach m $warnfail {
            if {$failtarget eq ""} { set failtarget $m }
        }
    }
    foreach m $onarch {
        if {$m eq $failtarget} continue
        set p [set eff($m,policy)]
        if {$p eq "must-pass" || $p eq "fail-gates"} {
            puts "OK $m [set eff($m,owner)]"
        } else {
            puts "SKIP $m [set eff($m,owner)]"
        }
    }
    if {$failtarget ne ""} { puts "FAIL $failtarget [set eff($failtarget,owner)]" }
    return
}

# -------------------------------------------------------------------- arms --
# The absence check (suite-tail) only applies to markers the running suites
# own: a consumer that boots with one suite must not fail for markers a
# sibling suite prints. Known suites map to the owner(s) of the markers they
# print; an unknown suite declares "any" (check every must-pass — a custom
# suite that claims success while skipping a must-pass capability is exactly
# what the check exists to catch; an overlay can declare a marker warn).
proc suite_owners {suite} {
    if {[string match "*freebsd-launchd-mach/*" $suite]} {
        # run.sh prints the launchd/Mach family AND the freebsd-compat leaf
        # family (FBSDGLUE + the *-LEAF probes), so both owners are in scope.
        return "nextbsd-userland nextbsd-freebsd-compat"
    }
    if {[string match "*nextbsd-iokit/*" $suite]} {
        return "nextbsd-kernel-extensions"
    }
    if {[string match "*freebsd-compat/*" $suite]} {
        return "nextbsd-freebsd-compat"
    }
    return "any"
}

puts "# generated by manifest/gen-arms.tcl — do not edit"
puts "# arch: $arch | suites: $suites | manifest: $base + $overlay"
puts "set nb_mustpass { $mustpass }"
puts "set nb_warnfail { $warnfail }"
puts "set nb_dbgmarks { $onarch }"

set scope {}
for {set i 0} {$i < $suites} {incr i} {
    set o [suite_owners [lindex $suite_list $i]]
    if {$o eq "any"} {
        set scope "any"
    } else {
        set scope [join [concat $scope $o] " "]
    }
}
if {$scope eq ""} { set scope "any" }
puts "set nb_scope { $scope }"
foreach m $markers {
    puts "set nb_owner($m) \"[set eff($m,owner)]\"" 
    puts "set nb_pol($m) \"[set eff($m,policy)]\"" 
    puts "set nb_reason($m) \"[esc [set eff($m,reason)]]\"" 
}


for {set i 0} {$i < $suites} {incr i} {
    set suite [lindex $suite_list $i]
    set suite [esc $suite]
    puts ""
    puts "set timeout \$env(NB_SUITE_TIMEOUT)"
    puts "puts \"==> running on-image suite: $suite\""
    puts "send \"r $suite\\r\""
    puts "expect {"
    puts "    timeout {"
    puts "        puts \"\\nFAIL: $suite printed no NEXTBSD-TEST-SUMMARY within the \$env(NB_SUITE_TIMEOUT)s budget (no sentinel — the suite hung or died)\""
    puts "        if {\$env(NB_DEBUG) ne \"\"} {"
    puts "            set fh \[open \$env(NB_LOG) r]"
    puts "            set d \[read \$fh]"
    puts "            close \$fh"
    puts "            set cmap \[list \"\\r\" {<CR>} \"\\n\" {<NL>} \"\\t\" {<TAB>}\]"
    puts "            set d2 \[string range \$d end-300 end]"
    puts "            puts \"\\nDBG-TIMEOUT: transcript \[string length \$d\] bytes; tail: \[string map \$cmap \$d2\]\""
    puts "        }"
    puts "        exit 2"
    puts "    }"
    # The marker arms come BEFORE the summary arm: expect re-scans the buffer
    # from the first arm after each exp_continue, so in a chunk that carries
    # markers and the sentinel together every marker is recorded first and the
    # summary (which ends the block) is seen last. A sentinel arm ahead of the
    # markers would end the block on the first scan and drop every marker in
    # the same chunk.
# The marker arms: one arm PER SUFFIX (re_marker_ok/fail/skip, from patterns.tcl)
# plus the runtime policy table above. The runners' expect takes the first arm
# in file order that matches anywhere in the buffer, so 93 sorted per-marker
# arms let a marker whose text arrives late match first and consume every
# marker in between; one pattern family consumes the stream in arrival order.
# The name is group 1 and the suffix is fixed per arm, because this expect
# does not populate expect_out(string)/expect_out(2,string) for the single-
# alternation pattern; nb_pol decides each marker's outcome.
    foreach sfx {OK FAIL SKIP} {
        set sfxl [string tolower $sfx]
    puts "    -re \$re_marker_$sfxl {"
    puts "        incr dbg_arms"
    puts "        set m \$expect_out(1,string)"
    puts "        set sfx $sfx"
    puts "        if {!\[info exists nb_pol(\$m)]} { puts \"\\nDBG-ARM: unlisted marker <\$m>-\$sfx — ignoring\"; exp_continue }"
    puts "        set pol \$nb_pol(\$m)"
    puts "        set r   \$nb_reason(\$m)"
    puts "        if {\$sfx eq \"OK\"} {"
    puts "            set nb_seen(\$m) 1"
    puts "            puts \"\\nOK: \$m\""
    puts "            exp_continue"
    puts "        }"
    puts "        if {\$sfx eq \"FAIL\"} {"
    puts "            if {\$pol eq \"must-pass\" || \$pol eq \"fail-gates\"} {"
    puts "                puts \"\\nFAIL: \$m — \$r\""
    puts "                exit 1"
    puts "            }"
    puts "            if {\$pol eq \"offarch\"} {"
    puts "                puts \"\\nINFO: \$m-FAIL (not expected on $arch — \$r)\""
    puts "                exp_continue"
    puts "            }"
    puts "            set nb_wfail(\$m) 1"
    puts "            puts \"\\nWARN: \$m-FAIL — \$r (informational)\""
    puts "            exp_continue"
    puts "        }"
    puts "        if {\$sfx eq \"SKIP\"} {"
    puts "            if {\$pol eq \"must-pass\"} {"
    puts "                puts \"\\nFAIL: \$m-SKIP — a must-pass capability self-skipped (absent from this image)\""
    puts "                exit 1"
    puts "            }"
    puts "            set nb_seen(\$m) 1"
    puts "            puts \"\\nWARN: \$m-SKIP — \$r\""
    puts "            exp_continue"
    puts "        }"
    puts "    }"
    }
    puts "    -re \$re_summary {"
    puts "        set nb_ok   \$expect_out(1,string)"
    puts "        set nb_fail \$expect_out(2,string)"
    puts "        set nb_skip \$expect_out(3,string)"
    puts "        set nb_warnfail_sum 0"
    puts "        foreach w \$nb_warnfail {"
    puts {            if {[info exists nb_wfail($w)]} { incr nb_warnfail_sum }}
    puts "        }"
    puts "        if {\$nb_fail > \$nb_warnfail_sum} {"
    puts "            puts \"\\nFAIL: $suite: NEXTBSD-TEST-SUMMARY ok=\$nb_ok fail=\$nb_fail skip=\$nb_skip — the suite's own verdict is a failure\""
    puts "            exit 1"
        puts "        }"
    puts "        if {\$nb_fail > 0} {"
    puts "            puts \"\\nOK: $suite: NEXTBSD-TEST-SUMMARY ok=\$nb_ok fail=\$nb_fail skip=\$nb_skip (\$nb_fail failure(s) are manifest-warn class; not gated)\""
    puts "        } else {"
    puts "            puts \"\\nOK: $suite: NEXTBSD-TEST-SUMMARY ok=\$nb_ok fail=0 skip=\$nb_skip\""
    puts "        }"
    puts "    }"
    puts "    -re {panic|Fatal trap|Fatal data abort} {"
    puts "        puts \"\\nFAIL: kernel panic during $suite\""
    puts "        exit 1"
    puts "    }"
    puts "    eof {"
    puts "        puts \"\\nFAIL: $suite died (serial stream closed) before printing NEXTBSD-TEST-SUMMARY\""
    puts "        if {\$env(NB_DEBUG) ne \"\"} {"
    puts "            set fh \[open \$env(NB_LOG) r]"
    puts "            set d \[read \$fh]"
    puts "            close \$fh"
    puts "            set cmap \[list \"\\r\" {<CR>} \"\\n\" {<NL>} \"\\t\" {<TAB>}\]"
    puts "            set d2 \[string range \$d end-300 end]"
    puts "            puts \"\\nDBG-EOF: transcript \[string length \$d\] bytes; tail: \[string map \$cmap \$d2\]\""
    puts "        }"
    puts "        exit 2"
    puts "    }"
    puts "}"
    puts "if {\$env(NB_DEBUG) ne \"\"} {"
    puts "    set dbgfull \"\""
    puts "    if {\[file exists \$env(NB_LOG)]} {"
    puts "        set fh \[open \$env(NB_LOG) r]"
    puts "        set dbgfull \[read \$fh]"
    puts "        close \$fh"
    puts "    }"
    puts "    set cmap \[list \"\\r\" {<CR>} \"\\n\" {<NL>} \"\\t\" {<TAB>}\]"
    puts "    set d2 \[string range \$dbgfull end-300 end]"
    puts "    puts \"\\nDBG: transcript \[string length \$dbgfull\] bytes; tail: \[string map \$cmap \$d2\]\""
    puts "    puts \"\\nDBG: markers recorded: \[llength \[array names nb_seen\]\]\""
    puts "    foreach m \[lrange \$nb_dbgmarks 0 7\] {"
    puts "        puts \"\\nDBG-MARK: <\$m> at OK/SKIP/FAIL = \[string first \$m-OK \$dbgfull\]/\[string first \$m-SKIP \$dbgfull\]/\[string first \$m-FAIL \$dbgfull\]\""
    puts "    }"
    puts "}"
}
puts ""
puts "# the suite section is done; suite-tail.exp.inc takes over (absence check,"
puts "# banner verdict, end-state) and teardown.exp.inc the poweroff."
