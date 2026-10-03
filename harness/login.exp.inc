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
        puts "\nFAIL: boot banner not seen within $timeout s (the global budget)"
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

# Get a usable shell, in two stages.
#
# Stage 1 waits for the nextbsd-fetch login banner ("Welcome to NextBSD!",
# run from /etc/zprofile at login, so it prints INSIDE the shell after the
# autologin -- proof the shell is alive), or a login prompt / the session
# message on an image that does not autologin. The CI images are
# headless-console (no desktop login window), so nextbsd-fetch always prints
# after a clean login; it is the hard "shell is alive" gate.
#
# Stage 2 (below) waits for the shell prompt ([#%$] $) -- proof the shell is
# idle and accepting input, which the banner alone does not establish (it
# renders before the shell settles). The % only counts once the banner (or
# login) has been seen, so a stray driver line ending in % before the banner
# can't false-trigger it.
#
# The window is capped (180s) so a hung image bails quickly instead of waiting
# out the whole NB_TIMEOUT_GLOBAL. The "login on console as ..." session message
# is a syslog line that only reaches the console when syslogd is unreachable
# (a lost race on arm64, nextbsd-userland#289), so it is a secondary signal,
# not the gate.
set _saved_login_timeout $timeout
if {$timeout > 180} { set timeout 180 }
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
    -re $re_fetch_banner {
        set at_login 0
        puts "\nOK: shell alive (nextbsd-fetch banner)"
    }
    "login:" { puts "\nOK: boot reached the login prompt" }
    -re $re_session_msg {
        set at_login 0
        puts "\nOK: boot logged in automatically as $expect_out(1,string)"
    }
}
set timeout $_saved_login_timeout

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
}
# Stage 2: the shell prompt (the shell is idle/ready). The % only counts once
# the fetch banner (or the login above) has already been seen, so a stray
# driver line ending in % before the banner can't false-trigger it. On timeout
# (the prompt never rendered), probe for a shell before concluding anything.
expect {
    timeout {
        send "\r"
        send "echo NB-SHELL-READY\r"
        expect {
            -timeout 90
            timeout {
                puts "\nFAIL: no shell prompt, and no shell responded to the probe"
                exit 2
            }
            -re $re_panic {
                puts "\nFAIL: kernel panic during boot"
                exit 1
            }
            "NB-SHELL-READY" {
                puts "\nOK: shell confirmed by probe"
            }
        }
    }
    -re $re_panic {
        puts "\nFAIL: kernel panic during boot"
        exit 1
    }
    -re $re_shell_prompt {
        puts "\nOK: shell prompt (idle/ready)"
    }
}
# admin is not root (and on the Apple image root is disabled), so wrap the
# privileged commands rather than repeating the test at each one. A function,
# so it behaves the same in sh and in zsh, which is admin's shell.
send "r() { if \[ \"\$(id -u)\" = 0 \]; then \"\$@\"; else sudo \"\$@\"; fi; }\r"
