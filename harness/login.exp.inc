# login.exp.inc — get a usable shell on the booted system.
#
# Banner: captured for the BOOT-BANNER manifest marker. getty's banner and
# hostnamed's synthesis race (launchd dispatches them in parallel): the
# first-boot banner consistently loses and shows 'Amnesiac', while kern.hostname
# is set correctly (HOSTNAMED-OK proves it downstream) and the second getty
# respawn shows the synthesized name. The verdict policy comes from the
# manifest (NB_BANNER_POLICY); a mismatch is RECORDED here and decided in
# suite-tail so the suite still runs in the meantime.
#
# Login: root is disabled the way Darwin does it (nextbsd-overlays f9dcd5b —
# the password field went from empty to "*"), so admin is the way in on the
# Apple image; the userland-native CI image still carries a live root, so a
# "Login incorrect" on admin falls back to root. Where automatic login is
# configured there is no prompt at all, so both paths are handled rather than
# assuming either.
#
# Exit 2 (not 1) for the "never got there" timeouts below: a boot that never
# completes is categorically different from an assertion that fails, and
# boot_soft must not hide it (nextbsd-userland#87/#117: an 8-minute hang once
# reported pass). Every consumer workflow re-gates on rc==2 regardless of
# boot_soft.

set early_name ""
set banner_fail ""
expect {
    timeout {
        puts "\nFAIL: boot banner not seen within 8 minutes"
        exit 2
    }
    -re $re_panic {
        puts "\nFAIL: kernel panic during boot"
        exit 1
    }
    -re $re_early_init {
        set early_name $expect_out(1,string)
        exp_continue
    }
    -re $re_boot_banner {
        set banner_name $expect_out(1,string)
        if {$banner_name eq "Amnesiac" || $banner_name eq "localhost" || ($early_name ne "" && $banner_name ne $early_name)} {
            set banner_fail "banner shows '$banner_name' (early-init synthesized '$early_name')"
            puts "\nWARN: BOOT-BANNER — $banner_fail (recorded; decided after the suite)"
        } else {
            puts "\nOK: BOOT-BANNER-OK — getty shows the synthesized hostname '$banner_name'"
        }
    }
}

# Boot completes and we get a shell, in one block. Splitting the wait from the
# decision was the original bug: on an image where automatic login works there
# is no prompt, so a wait-only block waits out eight minutes and the decision
# never runs.
#
# The "login on console as ..." session message cannot be relied on: it is a
# syslog message, not console output (LOG_CONS reaches the console only when
# syslogd is unreachable), so whether it appears at all is a race (lost on
# arm64 under qemu while a working shell sat on the console — nextbsd-userland#289).
# On timeout, probe for a shell before concluding anything.
set at_login 1
expect {
    timeout {
        puts "\n... no login prompt and no session message; probing for a shell"
        send "\r"
        send "echo NB-SHELL-READY\r"
        expect {
            -timeout 90
            timeout {
                puts "\nFAIL: no 'login:' prompt, no session message, and no shell responded"
                exit 2
            }
            -re $re_panic {
                puts "\nFAIL: kernel panic during boot"
                exit 1
            }
            "NB-SHELL-READY" {
                set at_login 0
                puts "\nOK: automatic session confirmed by probe"
            }
        }
    }
    -re $re_panic {
        puts "\nFAIL: kernel panic during boot"
        exit 1
    }
    "login:" { puts "\nOK: boot reached the login prompt" }
    -re $re_session_msg {
        set at_login 0
        puts "\nOK: boot logged in automatically as $expect_out(1,string)"
    }
}

if {$at_login} {
    send "admin\r"
    expect {
        timeout {
            puts "\nFAIL: no response after sending admin"
            exit 1
        }
        "Login incorrect" {
            # The Apple image disabled root; the userland-native image allows it.
            send "root\r"
            expect {
                timeout {
                    puts "\nFAIL: no response after sending root"
                    exit 1
                }
                "Login incorrect" {
                    puts "\nFAIL: both admin and root logins rejected"
                    exit 1
                }
                "Password:" { send "\r"; exp_continue }
                -re $re_shell_prompt { puts "\nOK: at root shell prompt" }
            }
        }
        "Password:" { send "\r"; exp_continue }
        -re $re_shell_prompt { puts "\nOK: logged in as admin" }
    }
} else {
    # Do NOT match a prompt: automatic login lands early, with driver attach
    # messages still arriving, so the prompt is often not the last thing in the
    # buffer. Ask for a marker instead; characters typed before the shell is
    # ready are buffered by the tty.
    send "\r"
    send "echo NB-SHELL-READY\r"
    expect {
        timeout {
            puts "\nFAIL: no shell response after automatic login"
            exit 1
        }
        "NB-SHELL-READY" { puts "\nOK: shell is responding" }
    }
}
# admin is not root (and on the Apple image root is disabled), so wrap the
# privileged commands rather than repeating the test at each one. A function,
# so it behaves the same in sh and in zsh, which is admin's shell.
send "r() { if \[ \"\$(id -u)\" = 0 \]; then \"\$@\"; else sudo \"\$@\"; fi; }\r"
