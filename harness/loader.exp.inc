# loader.exp.inc — the FreeBSD loader serial handshake, shared by every NextBSD
# boot harness. `source harness/loader.exp.inc` immediately after the guest
# spawn, then: nb_loader_contract (harness/contract.exp.inc) does the rest.
#
# Migrated from nextbsd/tests/loader.exp.inc, which was lifted from
# nextbsd-userland's tests/boot-test.sh, which hardened it over several flaky
# runs. The emulated UART (16550 on q35, pl011 on virt) drops the odd
# character in BOTH directions, so:
#   - input is paced at ~25 cps (send -s) rather than dumped at once;
#   - each command syncs on the loader's next "OK " prompt, never on the echo of
#     what we typed (run 26070245676 showed `boot_multicons` echoed back as
#     `boo_multicons` on a command the loader had in fact accepted);
#   - the final `boot` is re-sent if the loader rejects it, because a garbled
#     boot never self-recovers — it just sits at the prompt (run 28754808354).

# ~25 cps: brisk-typist cadence, slow enough for the UART to keep up.
set send_slow {1 .04}

# loader_autoboot <secs> — the no-typing path (NB_LOADER_ENV=1): the contract
# is already in the loader's environment from the ESP's loader.env
# (harness/loader-env.sh), so send NOTHING and let autoboot_delay run out.
# Returns 1 once the loader reports `Console: comconsole` (the file was read
# and applied), 0 if it reports any other console (the file was not applied:
# the caller types the contract instead, and the countdown it interrupts is
# still ahead in the stream).
proc loader_autoboot {secs} {
    global timeout re_loader_console
    set saved $timeout
    set timeout $secs
    expect {
        timeout { puts "\nFAIL: the loader never reported its console within ${secs}s"; exit 1 }
        -re $re_loader_console {
            set con $expect_out(1,string)
        }
    }
    set timeout $saved
    if {$con eq "comconsole"} {
        puts "\n==> loader.env applied (console=comconsole, boot_verbose=YES); autobooting, nothing typed"
        return 1
    }
    puts "\n==> loader reports console '$con', so loader.env was not applied; typing the contract"
    return 0
}

# loader_prompt <secs> — catch the autoboot countdown and stop at the OK prompt.
# Under -display none the loader's default `efi` console routes to serial on both
# arches, so the banner and the prompt come to us over -serial stdio. The EFI
# banner line is matched brand-agnostically: the ostype is NextBSD after the
# kernel rebrand, and neither a rebrand nor a new brand may break the handshake.
proc loader_prompt {secs} {
    global timeout re_hit_enter re_efi_banner
    set saved $timeout
    set timeout $secs
    expect {
        timeout { puts "\nFAIL: didn't see the loader autoboot prompt within ${secs}s"; exit 1 }
        -re $re_hit_enter  { send " " }
        "Booting"          { send " " }
        -re $re_efi_banner { send " " }
        "Loading /boot/loader" { send " " }
    }
    set timeout 30
    expect {
        timeout { puts "\nFAIL: didn't reach the loader OK prompt within 30s"; exit 1 }
        "OK " { puts "\n==> at loader prompt" }
    }
    set timeout $saved
}

# loader_set <cmd> — set one loader variable, robustly.
#   1. settle at the prompt (the loader is still printing when it first appears)
#   2. drain, so we can't latch the PREVIOUS command's OK
#   3. send paced
#   4. sync on the fresh OK
proc loader_set {cmd} {
    global timeout
    set saved $timeout
    set timeout 20
    sleep 0.3
    expect *
    send -s -- "$cmd\r"
    expect {
        timeout { puts "\nFAIL: no OK prompt after '$cmd' within 20s"; exit 1 }
        "OK "
    }
    set timeout $saved
}

# loader_boot <cmd> — issue the final boot command, retrying a garbled send.
# Success = the loader leaves the prompt to load the kernel: no "unknown
# command", no failed kernel load, and no fresh "OK " inside the settle window.
# `Loading kernel...` alone is not success: a `boot v` (dropped dash) prints it
# too, then "Failed to load kernel 'v'" and drops back to the prompt — so a
# boot-go line is confirmed against a short follow-up window first. The retry
# then reloads the default kernel, which the failed load unloaded.
proc loader_boot {cmd} {
    global timeout re_boot_go re_boot_fail
    set saved $timeout
    set timeout 10
    for {set try 1} {$try <= 5} {incr try} {
        sleep 0.3
        expect *
        send -s -- "$cmd\r"
        expect {
            "unknown command" {
                puts "\n==> loader garbled '$cmd' (try $try/5); resending"
                continue
            }
            -re $re_boot_fail {
                puts "\n==> loader could not boot after '$cmd' (garbled; try $try/5); resending"
                continue
            }
            -re $re_boot_go {
                if {[string match "---<<*" $expect_out(0,string)]} {
                    set timeout $saved
                    return
                }
                set timeout 3
                expect {
                    -re $re_boot_fail {
                        set timeout 10
                        puts "\n==> loader could not boot after '$cmd' (garbled; try $try/5); resending"
                        continue
                    }
                    -ex "---<<" { }
                    timeout { }
                }
                set timeout $saved
                return
            }
            "OK " {
                puts "\n==> loader still at prompt after '$cmd' (try $try/5); resending"
                continue
            }
            timeout {
                # No reject and no fresh prompt => the kernel is loading.
                set timeout $saved
                return
            }
        }
    }
    puts "\nFAIL: loader never accepted '$cmd' after 5 tries (UART input drop)"
    exit 1
}
