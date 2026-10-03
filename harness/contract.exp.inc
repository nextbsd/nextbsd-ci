# contract.exp.inc — THE loader contract. One place, every arch, every lane.
# (nextbsd-ci T1; "verbose at the loader, never baked into images".)
#
#   console=comconsole       CI runs with -display none; serial is the console
#   boot_serial=YES          the kernel prints to it
#   comconsole_speed=115200  the cadence the -serial stdio pipe assumes
#   boot_multicons=YES       keep the (absent) vidconsole slot quiet as well
#   boot_mutemsgs=NO         undo the shipped quiet console (overlays#363). The
#                            shipped image stays macOS-clean; CI needs the kernel
#                            messages, and the on-image markers ride the same line.
#                            `NO` (not `unset`) is deliberate: the loader's howto
#                            builder does `val != NULL && strcasecmp(val, "no") != 0`
#                            (sys/kern/subr_boot.c boot_env_to_howto), so `=NO`
#                            clears RB_MUTEMSGS while keeping the variable set.
#   boot -v                  RB_VERBOSE bypasses the mute in the kernel, so CI
#                            sees full boot output while shipped images stay quiet.
#                            This is the fix for the five-harness divergence:
#                            nextbsd's big boot-test.sh did a bare `boot`, the
#                            img/iso harnesses did `boot -v`, the userland fork
#                            did a bare `boot` — one answer now, in one place.
#
# mach.debug_enable / launchd_trace stay the NB_BOOT_TRACE=1-only opt-in
# (nextbsd#369): with the console un-muted, the trace points push thousands of
# blocking kernel printfs through the emulated UART, which buries the on-image
# test markers and perturbs timing-sensitive Mach handshakes. Set
# NB_BOOT_TRACE=1 for a root-cause run.
#
# Requires: loader.exp.inc (loader_prompt / loader_set / loader_boot).
proc nb_loader_contract {} {
    loader_prompt 60
    loader_set "set console=comconsole"
    loader_set "set boot_serial=YES"
    loader_set "set comconsole_speed=115200"
    loader_set "set boot_multicons=YES"
    loader_set "set boot_mutemsgs=NO"
    if {[expr {[info exists env(NB_BOOT_TRACE)] && $env(NB_BOOT_TRACE) eq "1"}]} {
        puts "\n==> NB_BOOT_TRACE=1: enabling mach.debug_enable + launchd_trace"
        loader_set "set mach.debug_enable=1"
        loader_set "set launchd_trace=1"
    }
    loader_boot "boot -v"
}

# boot-test.sh cats spawn -> loader -> contract -> login; the contract runs
# here, so the login block below starts only after `boot -v` is accepted.
nb_loader_contract
