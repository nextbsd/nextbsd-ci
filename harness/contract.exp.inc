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
# How it gets there: NOT by typing, whenever the image allows it. Typed input
# crosses the emulated UART, which corrupts it once the loader is on
# comconsole — `boot -v` arrived as `boot v` (the loader went looking for a
# kernel named 'v' and the boot timed out at the banner), an Enter arrived as
# NUL (no OK prompt ever came back). So boot-test.sh writes these same
# variables to the disk image's ESP as /efi/freebsd/loader.env
# (harness/loader-env.sh), the loader applies them before loader.conf and
# autoboot, and NB_LOADER_ENV=1 tells this proc to send nothing at all.
# `boot_verbose=YES` there is `boot -v` (both set RB_VERBOSE). boot_mutemsgs is
# the one variable it can't override — loader.conf is read after loader.env and
# the image ships "YES" — and it doesn't need to: RB_VERBOSE exempts the boot
# from the mute, which is exactly how the image's own nextbsd.conf says CI gets
# its kernel output.
#
# The typed contract below stays for media with no writable ESP (the live
# ISO), for an image whose ESP write failed, and for a loader that reports a
# console other than comconsole (loader.env not applied).
#
# Requires: loader.exp.inc (loader_autoboot / loader_prompt / loader_set /
# loader_boot).
proc nb_loader_contract {} {
    global env
    if {[info exists env(NB_LOADER_ENV)] && $env(NB_LOADER_ENV) eq "1"} {
        if {[loader_autoboot 60]} {
            return
        }
    }
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
