# teardown.exp.inc — power off THROUGH launchd, and verify it happened.
#
# Ported from nextbsd-userland's tests/boot-test.sh, the most hardened of the
# five diverged copies. `shutdown -p now` signals PID 1 with SIGUSR2 per the
# BSD init(8) protocol, so this stage gates nextbsd#398 (the pre-fix launchd
# treated SIGUSR2 as a debug-log toggle and the system stalled forever after
# "System shutdown time has arrived").
#
# Discriminators, because -no-reboot makes qemu exit on EITHER outcome:
#   "Powering system off"  = RB_POWEROFF honored  -> SHUTDOWN-P-OK
#   "Rebooting"            = wrong reboot_flags   -> FAIL (exit 1)
#   timeout                = the #398 stall        -> FAIL, then halt -p
#                           (bypasses init, so the runner is never left
#                            hanging; still exit 1)
#
# Two things historically made this stage fail intermittently, and neither was
# a stall in launchd:
#   1. The poweroff was timed from when the command went out rather than from
#      the last sign of life, so a slow-but-working shutdown could trip the
#      budget (vnlru and syncer are each granted "max 60 seconds" to stop).
#      Progress markers reset the clock, which still catches a genuine stall
#      (no output at all).
#   2. The poweroff was sent without waiting for a shell prompt. The previous
#      block can leave the rest of its line and the prompt unconsumed, and
#      sending into that races the tty: zsh sees an empty line, prints a fresh
#      prompt, and `shutdown` never runs at all. So synchronise on a sentinel
#      first, then send.

send "\r"
send "echo NB-PRE'-'SHUTDOWN\r"
expect {
    timeout           { puts "\nWARN: no prompt before poweroff; sending anyway" }
    "NB-PRE-SHUTDOWN" { exp_continue }
    -re {[#%$] $}     { }
}

send "r shutdown -p now\r"
set timeout 180
set shutdown_progress 0
expect {
    -re $re_shutdown_wait {
        set shutdown_progress 1
        exp_continue
    }
    timeout {
        if {$shutdown_progress} {
            puts "\nFAIL: SHUTDOWN-P — shutdown was progressing but produced nothing for 180s and never powered off"
        } else {
            puts "\nFAIL: SHUTDOWN-P — no response at all within 180s of shutdown -p (init-protocol stall; this is what nextbsd#398 was)"
        }
        send "\r"
        sleep 1
        send "r halt -p\r"
        expect { timeout {} eof {} "Uptime:" {} }
        catch { close }
        catch { wait }
        exit 1
    }
    -re $re_reboot {
        puts "\nFAIL: SHUTDOWN-P — system REBOOTED on shutdown -p (reboot_flags not honored, nextbsd#398)"
        catch { close }
        catch { wait }
        exit 1
    }
    -re $re_poweroff {
        puts "\nOK: SHUTDOWN-P-OK — launchd honored the init poweroff protocol (shutdown -p -> SIGUSR2 -> RB_HALT|RB_POWEROFF)"
        expect {
            timeout { puts "\nWARN: qemu did not exit after poweroff (informational)" }
            eof     { puts "\nOK: VM exited after poweroff" }
        }
    }
    eof {
        # Poweroff paths without a console banner (e.g. arm64 PSCI) go straight
        # to qemu exit. "Rebooting..." is always printed on the reboot path
        # (kern_shutdown.c), so a silent exit here is a poweroff.
        puts "\nOK: SHUTDOWN-P-OK — VM exited on shutdown -p (bannerless poweroff path)"
    }
}

# A clean poweroff hits eof, which auto-closes the spawn — an explicit `close`
# then throws "spawn id ... not open" and (uncaught) fails an otherwise-passing
# boot. Guard both so teardown never turns a green boot red. (nextbsd#369)
catch { close }
catch { wait }
